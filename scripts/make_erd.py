"""Draw docs/erd.png straight from sql/03_dw_tables.sql, so the diagram always matches the real tables."""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ddl = (ROOT / "sql" / "03_dw_tables.sql").read_text()

# ---- parse tables and columns
tables = {}
for name, body in re.findall(r"CREATE TABLE (dw\.\w+) \((.*?)\n\);", ddl, re.S):
    cols = []
    for line in body.splitlines():
        m = re.match(r"\s*\[?(\w+)\]?\s+(\w+)", line)
        if m and m.group(1).upper() not in ("CONSTRAINT", "PRIMARY"):
            cols.append((m.group(1), m.group(2).lower()))
    tables[name] = cols

dims = [t for t in tables if ".dim_" in t]
facts = [t for t in tables if ".fact_" in t]
owner = {t.split("dim_", 1)[1] + "_key": t for t in dims}           # dim_date -> date_key
ALIAS = {"order_date_key": "date_key", "expected_date_key": "date_key", "received_date_key": "date_key",
         "request_date_key": "date_key", "ship_date_key": "date_key", "snapshot_date_key": "date_key",
         "start_date_key": "date_key", "end_date_key": "date_key", "from_location_key": "location_key",
         "to_location_key": "location_key", "home_location_key": "location_key"}


def role(table, col):
    if table in dims and col == table.split("dim_", 1)[1] + "_key":
        return "PK"
    k = ALIAS.get(col, col)
    return "FK" if k in owner and owner[k] != table else ""


def node(table):
    head = "#1F4E79" if table in dims else "#7A2E2E"
    rows = []
    for c, typ in tables[table]:
        r = role(table, c)
        label = f"<b>{c}</b>" if r == "PK" else (f"<i>{c}</i>" if r == "FK" else c)
        badge = f'<font color="#1F4E79">{r}</font>' if r else " "
        rows.append(f'<tr><td align="left">{label}</td><td align="left"><font color="#888888">{typ}</font></td><td>{badge}</td></tr>')
    return (f'"{table}" [label=<<table border="0" cellborder="1" cellspacing="0" cellpadding="3" color="#cccccc">'
            f'<tr><td colspan="3" bgcolor="{head}"><font color="white"><b>{table}</b></font></td></tr>{"".join(rows)}</table>>];')


edges = set()
for t in facts + dims:
    for c, _ in tables[t]:
        if role(t, c) == "FK":
            edges.add((owner[ALIAS.get(c, c)], t))
edges.add(("dw.dim_product", "dw.dim_product_price"))

left = ["dw.dim_date", "dw.dim_location", "dw.dim_supplier"]
right = [d for d in dims if d not in left]
out = ['digraph erd {',
       'graph [rankdir=LR, splines=true, nodesep=0.25, ranksep=1.6, fontname="Helvetica", bgcolor="white"];',
       'node [shape=plain, fontname="Helvetica", fontsize=10];',
       'edge [color="#a0a0a0", penwidth=0.8, arrowhead=crow, arrowsize=0.7];']
out += [node(t) for t in tables]
for a, b in sorted(edges):
    if a in right and b in facts:          # right-hand dimensions sit to the right of the facts
        out.append(f'"{b}" -> "{a}" [dir=back, arrowtail=crow];')
    else:
        out.append(f'"{a}" -> "{b}";')
out.append("{rank=same; " + " ".join(f'"{t}"' for t in left) + "}")
out.append("{rank=same; " + " ".join(f'"{t}"' for t in right) + "}")
out.append("}")
dot = ROOT / "docs" / "erd.dot"
dot.write_text("\n".join(out))
subprocess.run(["dot", "-Tpng", "-Gdpi=100", str(dot), "-o", str(ROOT / "docs" / "erd.png")], check=True)
print("docs/erd.png:", len(dims), "dimensions,", len(facts), "facts,", len(edges), "relationships")
