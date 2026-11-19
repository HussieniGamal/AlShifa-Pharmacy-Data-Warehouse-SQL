"""
Verify the T-SQL logic without SQL Server.

* loads the generated CSV extracts into DuckDB staging tables (all text, like BULK INSERT)
* builds the dw tables from 03_dw_tables.sql
* runs every "-- @test" block from 04_load_procedures.sql, transpiled T-SQL -> DuckDB
* runs every query in the analysis scripts (05+) and saves the results to docs/results/

Usage:  python scripts/test_sql.py --data data/generated [--db /tmp/alshifa.duckdb]
"""
import argparse
import re
import time
from pathlib import Path

import duckdb
import sqlglot

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "sql"

STG_FILES = {
    "erp_branches": "erp/branches.csv", "erp_warehouses": "erp/warehouses.csv",
    "erp_suppliers": "erp/suppliers.csv", "erp_products": "erp/products.csv",
    "erp_price_history": "erp/price_history.csv", "erp_employees": "erp/employees.csv",
    "erp_promotions": "erp/promotions.csv", "erp_purchase_orders": "erp/purchase_orders.csv",
    "crm_customers": "crm/customers.csv", "pos_sales_lines": "pos/sales_lines_*.csv",
    "wms_transfers_to_branches": "wms/transfers_to_branches.csv",
    "wms_inventory_month_end": "wms/inventory_month_end.csv", "wms_batches_current": "wms/batches_current.csv",
    "wms_expiry_writeoffs": "wms/expiry_writeoffs.csv", "wms_stockout_events": "wms/stockout_events.csv",
}


def tsql_to_duck(sql: str) -> str:
    out = sqlglot.transpile(sql, read="tsql", write="duckdb", pretty=False)
    return ";\n".join(out)


def load_staging(con, data: Path):
    con.execute("CREATE SCHEMA IF NOT EXISTS stg; CREATE SCHEMA IF NOT EXISTS dw; CREATE SCHEMA IF NOT EXISTS ref; CREATE SCHEMA IF NOT EXISTS mart;")
    for t, rel in STG_FILES.items():
        con.execute(f"CREATE OR REPLACE TABLE stg.{t} AS SELECT * FROM read_csv('{data / rel}', all_varchar=true, header=true, union_by_name=true)")
        n = con.execute(f"select count(*) from stg.{t}").fetchone()[0]
        print(f"  stg.{t:<28} {n:>10,}")


def create_dw(con):
    ddl = (SQL / "03_dw_tables.sql").read_text()
    stmts = [s for s in re.split(r";\s*\n", ddl) if re.search(r"^\s*(CREATE TABLE|INSERT INTO ref)", s, re.M)]
    for s in stmts:
        s = s[s.find("CREATE TABLE") if "CREATE TABLE" in s else s.find("INSERT"):]
        m = re.search(r"CREATE TABLE (\S+)", s)
        if m and "IDENTITY" in s:
            seq = "seq_" + m.group(1).replace(".", "_")
            con.execute(f"CREATE SEQUENCE IF NOT EXISTS {seq} START 1")
            s = re.sub(r"(BIG)?INT IDENTITY\(1,1\)", f"BIGINT DEFAULT nextval('{seq}')", s)
        s = re.sub(r"\s+REFERENCES [\w.]+\(\w+\)", "", s)
        s = re.sub(r",\s*CONSTRAINT \w+ PRIMARY KEY \([^)]*\)", "", s)
        s = s.replace("[", "").replace("]", "")
        s = re.sub(r"--[^\n]*", "", s)
        s = re.sub(r"\bBIT\b", "TINYINT", s)          # SQL Server BIT compares to 1/0 like an integer
        con.execute(tsql_to_duck(s))
    # unknown members (SET IDENTITY_INSERT in SQL Server)
    con.execute("INSERT INTO dw.dim_employee (employee_key, employee_code, full_name, gender, job_title, department, hire_date) VALUES (-1,'UNKNOWN','Unknown employee','U','Unknown','Unknown','1900-01-01')")
    con.execute("INSERT INTO dw.dim_customer (customer_key, customer_code, age_band, loyalty_tier) VALUES (-1,'WALK-IN','Unknown','Not a member')")
    con.execute("INSERT INTO dw.dim_promotion (promotion_key, promo_code, promo_name, promo_type, discount_pct) VALUES (-1,'NONE','No promotion','None',0)")


def dim_date(con):
    # SQL Server builds this with a recursive CTE; same columns and rules here
    con.execute("""
    INSERT INTO dw.dim_date
    SELECT year(dt)*10000+month(dt)*100+day(dt), dt, year(dt), quarter(dt), month(dt), monthname(dt),
           strftime(dt,'%Y-%m'), day(dt), dayname(dt), (date_diff('day', DATE '2000-01-01', dt) % 7)+1,
           ((date_diff('day', DATE '2000-01-01', dt) % 7) in (0,6))::TINYINT,
           exists(select 1 from ref.calendar_event e where e.event_name='Ramadan' and dt between e.start_date and e.end_date)::TINYINT,
           exists(select 1 from ref.calendar_event e where e.event_name like 'Eid%' and dt between e.start_date and e.end_date)::TINYINT,
           exists(select 1 from ref.calendar_event e where e.event_name<>'Ramadan' and dt between e.start_date and e.end_date)::TINYINT,
           case when month(dt) in (12,1,2) then 'Winter' when month(dt) in (3,4,5) then 'Spring'
                when month(dt) in (6,7,8) then 'Summer' else 'Autumn' end
    FROM (SELECT unnest(generate_series(DATE '2023-01-01', DATE '2026-12-31', INTERVAL 1 DAY))::DATE AS dt)""")


def run_load_blocks(con):
    text = (SQL / "04_load_procedures.sql").read_text()
    for name, body in re.findall(r"-- @test (\w+)\n(.*?)-- @end", text, re.S):
        t0 = time.time()
        body = body.strip().rstrip(";")
        if body.upper().startswith("SELECT"):          # MERGE source -> insert by name
            sql = f"INSERT INTO dw.{name} BY NAME {tsql_to_duck(body)}"
        else:
            sql = tsql_to_duck(body)
        try:
            con.execute(sql)
        except Exception as e:
            print(f"  !! {name}: {e}\n{sql[:1500]}")
            raise
        n = con.execute(f"select count(*) from dw.{name}").fetchone()[0]
        print(f"  dw.{name:<28} {n:>10,}   ({time.time() - t0:.1f}s)")


def split_queries(text):
    """Split an analysis script into (title, sql) pairs. Titles come from '-- Q..' comment lines."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    parts = [p.strip() for p in re.split(r";\s*\n|\nGO\s*\n", text) if p.strip()]
    out = []
    for p in parts:
        title = re.findall(r"^--\s*(Q\d+[^\n]*)", p, re.M)
        code = "\n".join(l for l in p.splitlines()
                         if not l.strip().startswith("--") and l.strip().upper() != "GO").strip()
        if not code or code.upper().startswith(("USE ", "GO", "SET ", "PRINT ")):
            continue
        out.append((title[-1] if title else "", code))
    return out


def run_analysis(con, files, results: Path):
    results.mkdir(parents=True, exist_ok=True)
    for f in files:
        n = con.execute("select count(*) from dw.fact_sales").fetchone()[0]
        md = [f"# Results: {f.name}\n",
              f"_Generated by `scripts/test_sql.py`: every query below was run on the simulated data set "
              f"({n:,} sales lines). The T-SQL was transpiled to DuckDB for this automated run; "
              f"top 25 rows shown._\n"]
        for title, code in split_queries(f.read_text()):
            if code.upper().startswith(("CREATE OR ALTER VIEW", "CREATE VIEW")):
                code = re.sub(r"CREATE OR ALTER VIEW", "CREATE OR REPLACE VIEW", code, flags=re.I)
                con.execute(tsql_to_duck(code.replace("CREATE OR REPLACE VIEW", "CREATE VIEW")).replace("CREATE VIEW", "CREATE OR REPLACE VIEW", 1))
                print(f"  view ok: {code.split()[4] if len(code.split())>4 else ''}")
                continue
            t0 = time.time()
            try:
                df = con.execute(tsql_to_duck(code)).df()
            except Exception as e:
                print(f"  !! {f.name} {title}: {e}\n{tsql_to_duck(code)[:1200]}")
                raise
            print(f"  {f.name:<34} {title[:60]:<60} {len(df):>6} rows ({time.time() - t0:.1f}s)")
            md.append(f"\n## {title or 'query'}\n")
            md.append(df.head(25).to_markdown(index=False, floatfmt=",.2f"))
        (results / (f.stem + ".md")).write_text("\n".join(md))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(ROOT / "data" / "generated"))
    ap.add_argument("--db", default=":memory:")
    ap.add_argument("--only-analysis", action="store_true")
    a = ap.parse_args()
    con = duckdb.connect(a.db)
    if not a.only_analysis:
        print("staging:"); load_staging(con, Path(a.data))
        print("dw tables:"); create_dw(con); dim_date(con)
        print("load blocks:"); run_load_blocks(con)
    files = sorted(f for f in SQL.glob("*.sql") if int(f.name[:2]) >= 5)
    print("analysis:"); run_analysis(con, files, ROOT / "docs" / "results")


if __name__ == "__main__":
    main()
