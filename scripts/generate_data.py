"""
Al Shifa Al Ajil Pharmacies - source system extract generator (Phase 1)

Simulates two years (2024-2025) of operations for a 35-branch pharmacy chain and
writes the CSV extracts that each source system would hand to the data warehouse:

  erp/   branches, warehouses, suppliers, products, price_history, employees, promotions,
         purchase_orders
  pos/   sales_lines_YYYY_MM.csv   (one file per month, invoice line grain)
  crm/   customers
  wms/   transfers_to_branches, inventory_month_end, batches_current, expiry_writeoffs,
         stockout_events

The behaviour is simulated but deliberately realistic: winter flu season, Ramadan and Eid,
Saudi weekends (Fri/Sat), late-evening peaks, chronic patients refilling every ~30 days,
supplier delays, national shortages, promotions, a retail price increase, new branches,
and a small amount of dirty data for the cleaning step.

Usage:
    python scripts/generate_data.py --scale 0.5 --out data/generated
    scale 1.0  ~ 4 M invoices / 7.5 M lines  (full size)
    scale 0.1  ~ 0.4 M invoices                (quick test)
"""
import argparse
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

# Unix line endings on every OS so SQL Server BULK INSERT can use ROWTERMINATOR 0x0a
_to_csv = pd.DataFrame.to_csv
pd.DataFrame.to_csv = lambda self, *a, **k: _to_csv(self, *a, **{"lineterminator": "\n", **k})

ROOT = Path(__file__).resolve().parents[1]
START, END = date(2024, 1, 1), date(2025, 12, 31)
SNAPSHOT = END

# Hijri calendar events (Gregorian dates, Saudi official calendar)
RAMADAN = [(date(2024, 3, 11), date(2024, 4, 9)), (date(2025, 3, 1), date(2025, 3, 29))]
EID_FITR = [(date(2024, 4, 10), date(2024, 4, 13)), (date(2025, 3, 30), date(2025, 4, 2))]
EID_ADHA = [(date(2024, 6, 16), date(2024, 6, 19)), (date(2025, 6, 6), date(2025, 6, 9))]
NATIONAL_DAY = [date(2024, 9, 23), date(2025, 9, 23)]
FOUNDING_DAY = [date(2024, 2, 22), date(2025, 2, 22)]


def in_ranges(d, ranges):
    return any(a <= d <= b for a, b in ranges)


def build_calendar():
    days = pd.date_range(START, END, freq="D")
    cal = pd.DataFrame({"date": days})
    d = cal["date"].dt.date
    cal["is_ramadan"] = d.map(lambda x: in_ranges(x, RAMADAN))
    cal["is_eid"] = d.map(lambda x: in_ranges(x, EID_FITR + EID_ADHA))
    # the 10 days before each Eid: gifting / fragrance / beauty peak
    pre = [(a - timedelta(days=10), a - timedelta(days=1)) for a, _ in EID_FITR + EID_ADHA]
    cal["is_pre_eid"] = d.map(lambda x: in_ranges(x, pre))
    cal["is_holiday"] = d.isin(NATIONAL_DAY + FOUNDING_DAY) | cal["is_eid"]
    cal["dow"] = cal["date"].dt.dayofweek  # Mon=0 ... Fri=4, Sat=5
    cal["month"] = cal["date"].dt.month
    cal["year"] = cal["date"].dt.year
    return cal


# ----------------------------------------------------------------------------- masters
FIRST_M = "Abdullah Mohammed Ahmed Khalid Faisal Saud Omar Fahad Sultan Turki Nasser Majed Yousef Ibrahim Hassan Ali Hamad Saleh Bandar Ziyad Mansour Waleed Tariq Rakan Mazen Amr Mahmoud Mostafa Karim Hossam".split()
FIRST_F = "Noura Sara Reem Lama Hessa Nouf Maha Haya Abeer Rawan Jawaher Lulwa Dana Ghada Asma Amal Hind Shahad Raghad Mona Fatimah Aisha Mariam Yasmin Salma Nada Rana Heba Dina Aya".split()
LAST = "Al-Otaibi Al-Qahtani Al-Ghamdi Al-Zahrani Al-Shehri Al-Harbi Al-Mutairi Al-Dosari Al-Subaie Al-Anazi Al-Shammari Al-Juhani Al-Malki Al-Omari Al-Qurashi Al-Sulami Al-Rashidi Al-Yami Al-Balawi Al-Asmari Hassan Mostafa Abdelrahman Fathy Saeed Kamal Nabil Farouk Hamdy Salem".split()

BRANCHES = [
    # code, city, region, district, type, size_sqm, open_date, is_24h, warehouse
    ("RUH-001", "Riyadh", "Central", "Al Olaya", "Street", 220, "2012-04-01", 1, "DC-RUH"),
    ("RUH-002", "Riyadh", "Central", "Al Malqa", "Street", 180, "2014-09-15", 0, "DC-RUH"),
    ("RUH-003", "Riyadh", "Central", "Al Yasmin", "Residential", 140, "2015-02-01", 0, "DC-RUH"),
    ("RUH-004", "Riyadh", "Central", "Al Narjis", "Residential", 150, "2018-06-10", 0, "DC-RUH"),
    ("RUH-005", "Riyadh", "Central", "Al Nakheel", "Mall", 260, "2016-11-20", 0, "DC-RUH"),
    ("RUH-006", "Riyadh", "Central", "Al Rawdah", "Street", 160, "2013-03-05", 0, "DC-RUH"),
    ("RUH-007", "Riyadh", "Central", "Al Sulimaniyah", "Hospital", 120, "2017-01-12", 1, "DC-RUH"),
    ("RUH-008", "Riyadh", "Central", "Hittin", "Mall", 300, "2019-10-01", 0, "DC-RUH"),
    ("RUH-009", "Riyadh", "Central", "Al Aqiq", "Street", 170, "2020-05-18", 0, "DC-RUH"),
    ("RUH-010", "Riyadh", "Central", "Ar Rabwah", "Residential", 130, "2014-08-08", 0, "DC-RUH"),
    ("RUH-011", "Riyadh", "Central", "Al Muruj", "Street", 150, "2021-02-14", 0, "DC-RUH"),
    ("RUH-012", "Riyadh", "Central", "Dhahrat Laban", "Residential", 120, "2022-07-01", 0, "DC-RUH"),
    ("RUH-013", "Riyadh", "Central", "King Fahd Rd", "Highway", 200, "2018-12-01", 1, "DC-RUH"),
    ("RUH-014", "Riyadh", "Central", "Al Arid", "Residential", 140, "2025-03-15", 0, "DC-RUH"),
    ("JED-001", "Jeddah", "Western", "Al Rawdah", "Street", 210, "2013-05-20", 1, "DC-JED"),
    ("JED-002", "Jeddah", "Western", "Al Zahra", "Residential", 150, "2015-10-10", 0, "DC-JED"),
    ("JED-003", "Jeddah", "Western", "Al Shati", "Mall", 280, "2017-04-04", 0, "DC-JED"),
    ("JED-004", "Jeddah", "Western", "Al Salamah", "Street", 160, "2016-01-25", 0, "DC-JED"),
    ("JED-005", "Jeddah", "Western", "Al Naeem", "Hospital", 110, "2019-08-19", 1, "DC-JED"),
    ("JED-006", "Jeddah", "Western", "Obhur", "Residential", 130, "2021-11-11", 0, "DC-JED"),
    ("JED-007", "Jeddah", "Western", "Al Hamdaniyah", "Residential", 130, "2025-06-01", 0, "DC-JED"),
    ("MKK-001", "Makkah", "Western", "Al Aziziyah", "Street", 190, "2014-06-06", 1, "DC-JED"),
    ("MKK-002", "Makkah", "Western", "Al Awali", "Residential", 140, "2018-03-03", 0, "DC-JED"),
    ("MKK-003", "Makkah", "Western", "Al Shawqiyah", "Hospital", 110, "2020-09-09", 1, "DC-JED"),
    ("MED-001", "Madinah", "Western", "Quba", "Street", 170, "2015-12-12", 0, "DC-JED"),
    ("MED-002", "Madinah", "Western", "Al Azhari", "Residential", 130, "2019-02-20", 0, "DC-JED"),
    ("MED-003", "Madinah", "Western", "King Abdullah Rd", "Mall", 220, "2022-01-30", 0, "DC-JED"),
    ("DMM-001", "Dammam", "Eastern", "Al Faisaliyah", "Street", 180, "2016-07-07", 1, "DC-RUH"),
    ("DMM-002", "Dammam", "Eastern", "Al Shati", "Mall", 240, "2018-11-15", 0, "DC-RUH"),
    ("DMM-003", "Dammam", "Eastern", "Al Nur", "Residential", 130, "2023-04-01", 0, "DC-RUH"),
    ("KHB-001", "Al Khobar", "Eastern", "Al Aqrabiyah", "Street", 170, "2017-09-01", 0, "DC-RUH"),
    ("KHB-002", "Al Khobar", "Eastern", "Al Hamra", "Mall", 230, "2025-09-10", 0, "DC-RUH"),
    ("BUR-001", "Buraidah", "Central", "Al Iskan", "Street", 160, "2019-05-05", 0, "DC-RUH"),
    ("BUR-002", "Buraidah", "Central", "Al Rayyan", "Residential", 120, "2021-06-20", 0, "DC-RUH"),
    ("AHB-001", "Abha", "Southern", "Al Manhal", "Street", 150, "2020-12-01", 0, "DC-JED"),
]
TYPE_TRAFFIC = {"Street": 1.0, "Residential": 0.8, "Mall": 1.15, "Hospital": 0.95, "Highway": 1.05}

SUPPLIERS = [
    # code, name, type, city, agreed_lead_days, delay_mean, fill_rate, payment_terms
    ("SUP-01", "Gulf Medical Distribution Co.", "Distributor", "Riyadh", 3, 0.5, 0.98, 60),
    ("SUP-02", "Arabian Pharma Supplies", "Distributor", "Jeddah", 4, 1.0, 0.96, 60),
    ("SUP-03", "Najd Healthcare Trading", "Distributor", "Riyadh", 5, 4.0, 0.88, 45),
    ("SUP-04", "Red Sea Drug Store Est.", "Distributor", "Jeddah", 4, 1.5, 0.95, 90),
    ("SUP-05", "Peninsula Cold Chain Logistics", "Distributor", "Dammam", 2, 0.8, 0.93, 60),
    ("SUP-06", "Al Waha Beauty Trading", "Distributor", "Riyadh", 7, 2.0, 0.94, 90),
    ("SUP-07", "Desert Rose Fragrances Co.", "Distributor", "Jeddah", 10, 3.0, 0.92, 90),
    ("SUP-08", "Taiba Consumer Health", "Distributor", "Madinah", 6, 1.0, 0.97, 60),
    ("SUP-09", "Al Shifa Private Label Factory", "Manufacturer", "Riyadh", 14, 2.5, 0.99, 30),
]

# category seasonality: month -> multiplier
def season_curve(peak_months, high, low_months=(), low=1.0):
    return {m: (high if m in peak_months else low if m in low_months else 1.0) for m in range(1, 13)}

SEASON = {
    "Cold, Cough & Flu": season_curve((11, 12, 1, 2), 1.75, (6, 7, 8), 0.6),
    "Antibiotics": season_curve((11, 12, 1, 2), 1.35, (6, 7, 8), 0.8),
    "Anti-infectives": season_curve((12, 1, 2), 1.4),
    "Allergy": season_curve((3, 4, 10), 1.5, (7, 8), 0.85),
    "Asthma & COPD": season_curve((3, 4, 11, 12), 1.2),
    "Sun Care": season_curve((5, 6, 7, 8), 1.9, (11, 12, 1, 2), 0.55),
    "Moisturizers": season_curve((11, 12, 1, 2), 1.4, (6, 7, 8), 0.8),
    "Immunity": season_curve((10, 11, 12, 1, 2), 1.5),
    "Multivitamins": season_curve((1, 9), 1.25),
    "Manage Your Weight": season_curve((1, 5), 1.45),
    "Smoking Cessation": season_curve((1,), 1.6),
    "Hair Care": season_curve((6, 7, 8), 1.15),
}
DEPT_BASE = {  # relative purchase frequency per item by department
    "Prescription Medicines": 1.0, "OTC Medicines": 2.4, "Vitamins & Supplements": 0.9,
    "Beauty & Skincare": 0.7, "Personal Care": 0.9, "Fragrances": 0.35, "Baby & Mother": 0.8,
    "Medical Devices": 0.35, "Health Food": 0.5,
}
# share of department demand by branch type
TYPE_MIX = {
    "Mall": {"Beauty & Skincare": 1.8, "Fragrances": 2.4, "Prescription Medicines": 0.7, "Personal Care": 1.3},
    "Hospital": {"Prescription Medicines": 1.9, "Medical Devices": 1.6, "Beauty & Skincare": 0.5, "Fragrances": 0.4},
    "Residential": {"Baby & Mother": 1.7, "Prescription Medicines": 1.15, "Fragrances": 0.6},
    "Highway": {"OTC Medicines": 1.3, "Personal Care": 1.2},
    "Street": {},
}
HOURS = np.arange(24)
HOUR_NORMAL = np.array([.6, .3, .15, .1, .08, .1, .3, .8, 1.6, 2.6, 3.2, 3.6, 3.5, 2.6, 2.3, 2.4,
                        2.9, 3.5, 4.2, 4.9, 5.4, 5.6, 4.8, 2.4])
HOUR_RAMADAN = np.array([2.2, 2.0, 1.5, .7, .2, .1, .1, .2, .4, .8, 1.2, 1.5, 1.6, 1.6, 1.6, 1.7,
                         1.8, 1.5, 1.0, 2.0, 4.6, 5.6, 5.8, 4.2])
HOUR_FRIDAY = HOUR_NORMAL.copy(); HOUR_FRIDAY[9:14] *= 0.35; HOUR_FRIDAY[16:23] *= 1.25


def make_masters(rng, scale, out):
    erp, crm = out / "erp", out / "crm"
    erp.mkdir(parents=True, exist_ok=True); crm.mkdir(parents=True, exist_ok=True)

    br = pd.DataFrame(BRANCHES, columns=["branch_code", "city", "region", "district", "branch_type",
                                         "size_sqm", "open_date", "is_24h", "warehouse_code"])
    br["branch_name"] = "Al Shifa Al Ajil - " + br["district"] + " (" + br["city"] + ")"
    br["open_date"] = pd.to_datetime(br["open_date"])
    br["traffic"] = br["branch_type"].map(TYPE_TRAFFIC) * (br["size_sqm"] / 170) ** 0.6 * rng.uniform(0.85, 1.15, len(br))
    wh = pd.DataFrame([("DC-RUH", "Riyadh Central Distribution Center", "Riyadh", "Central"),
                       ("DC-JED", "Jeddah Western Distribution Center", "Jeddah", "Western")],
                      columns=["warehouse_code", "warehouse_name", "city", "region"])
    sup = pd.DataFrame(SUPPLIERS, columns=["supplier_code", "supplier_name", "supplier_type", "city",
                                           "agreed_lead_days", "delay_mean", "fill_rate", "payment_terms_days"])

    prod = pd.read_csv(ROOT / "data" / "reference" / "products.csv")
    # supplier assignment by department
    def pick_sup(r):
        if r.is_private_label: return "SUP-09"
        if r.is_cold_chain: return "SUP-05"
        if r.department == "Fragrances": return "SUP-07"
        if r.department in ("Beauty & Skincare", "Personal Care"): return rng.choice(["SUP-06", "SUP-08"], p=[.65, .35])
        if r.department in ("Prescription Medicines",): return rng.choice(["SUP-01", "SUP-02", "SUP-03", "SUP-04"], p=[.35, .3, .2, .15])
        return rng.choice(["SUP-01", "SUP-02", "SUP-04", "SUP-08"], p=[.3, .3, .2, .2])
    prod["supplier_code"] = [pick_sup(r) for r in prod.itertuples()]
    # popularity: long tail inside every department
    prod["popularity"] = prod["department"].map(DEPT_BASE) * rng.lognormal(0, 0.9, len(prod))
    prod.loc[prod["category"].isin(["Pain & Fever", "Cold, Cough & Flu"]), "popularity"] *= 1.6
    prod.loc[prod["list_price_sar"] > 300, "popularity"] *= 0.35
    # a slice of the range barely sells (dead stock candidates)
    slow = rng.random(len(prod)) < 0.08
    prod.loc[slow, "popularity"] *= 0.06
    prod["is_slow_mover_truth"] = slow.astype(int)

    # retail price increase of 5% on 1 Feb 2025 (regulated Rx/OTC drug prices unchanged)
    regulated = prod["source"].eq("SFDA drugs list")
    ph = [pd.DataFrame({"product_code": prod["product_code"], "valid_from": "2023-01-01",
                        "valid_to": np.where(regulated, "9999-12-31", "2025-01-31"),
                        "list_price_sar": prod["list_price_sar"], "unit_cost_sar": prod["unit_cost_sar"]})]
    nr = prod[~regulated]
    ph.append(pd.DataFrame({"product_code": nr["product_code"], "valid_from": "2025-02-01", "valid_to": "9999-12-31",
                            "list_price_sar": (nr["list_price_sar"] * 1.05).round(2),
                            "unit_cost_sar": (nr["unit_cost_sar"] * 1.03).round(2)}))
    price_hist = pd.concat(ph).sort_values(["product_code", "valid_from"])

    # employees (Phase 1: branch and area staff; head office departments come in Phase 2)
    emps = []
    eid = 10001
    def person():
        g = rng.choice(["M", "F"], p=[.62, .38])
        first = rng.choice(FIRST_M if g == "M" else FIRST_F)
        return g, f"{first} {rng.choice(LAST)}"
    area = {}
    for reg in ["Central", "Western", "Eastern", "Southern"]:
        g, n = person()
        area[reg] = f"E{eid}"
        emps.append((f"E{eid}", n, g, "Area Manager", "Operations", None, reg, None, "2016-01-01")); eid += 1
    for b in br.itertuples():
        hire0 = max(pd.Timestamp("2016-01-01"), b.open_date - pd.Timedelta(days=30))
        g, n = person(); bm = f"E{eid}"
        emps.append((bm, n, g, "Branch Manager", "Operations", area[b.region], b.region, b.branch_code, hire0.date())); eid += 1
        n_ph = 2 + int(b.is_24h) * 2 + int(b.size_sqm > 200)
        for _ in range(n_ph):
            g, n = person()
            emps.append((f"E{eid}", n, g, rng.choice(["Pharmacist", "Senior Pharmacist"], p=[.7, .3]), "Operations",
                         bm, b.region, b.branch_code, (hire0 + pd.Timedelta(days=int(rng.integers(0, 2500)))).date())); eid += 1
        for _ in range(1 + int(b.is_24h) + int(b.branch_type == "Mall")):
            g, n = person()
            emps.append((f"E{eid}", n, g, "Pharmacy Assistant", "Operations", bm, b.region, b.branch_code,
                         (hire0 + pd.Timedelta(days=int(rng.integers(0, 2500)))).date())); eid += 1
    emp = pd.DataFrame(emps, columns=["employee_code", "full_name", "gender", "job_title", "department",
                                      "manager_code", "region", "branch_code", "hire_date"])
    emp["hire_date"] = pd.to_datetime(emp["hire_date"]).clip(upper=pd.Timestamp("2025-11-30"))
    # nobody works in a branch before it opens
    opn = emp["branch_code"].map(br.set_index("branch_code")["open_date"])
    emp["hire_date"] = np.where(opn.notna() & (emp["hire_date"] < opn - pd.Timedelta(days=30)),
                                opn - pd.Timedelta(days=30), emp["hire_date"])

    # loyalty customers
    n_cust = int(60000 * scale) + 2000
    home = rng.choice(br["branch_code"], size=n_cust, p=(br["traffic"] / br["traffic"].sum()).values)
    g = rng.choice(["M", "F"], size=n_cust, p=[.48, .52])
    age = np.clip(rng.normal(41, 14, n_cust), 18, 90).astype(int)
    join = pd.Series(pd.Timestamp("2019-01-01") + pd.to_timedelta(rng.integers(0, 7 * 365, n_cust), unit="D"))
    cust = pd.DataFrame({"customer_code": [f"C{700001 + i}" for i in range(n_cust)], "gender": g,
                         "birth_year": 2025 - age, "home_branch_code": home,
                         "join_date": join.clip(upper=pd.Timestamp("2025-12-31")),
                         "loyalty_tier": rng.choice(["Blue", "Silver", "Gold"], n_cust, p=[.7, .22, .08]),
                         "has_insurance": (rng.random(n_cust) < 0.58).astype(int)})
    cust["city"] = cust["home_branch_code"].map(br.set_index("branch_code")["city"])
    # new-branch customers cannot join before the branch opens
    cust["join_date"] = np.maximum(cust["join_date"], cust["home_branch_code"].map(br.set_index("branch_code")["open_date"]))

    promos = pd.DataFrame([
        ("PR-2401", "Winter Wellness", "Percent Off", 0.20, "2024-01-01", "2024-01-31", "Vitamins & Supplements", None),
        ("PR-2402", "Ramadan Beauty Nights", "Percent Off", 0.25, "2024-03-11", "2024-04-09", "Beauty & Skincare", None),
        ("PR-2403", "Eid Fragrance Gift", "Percent Off", 0.30, "2024-03-31", "2024-04-12", "Fragrances", None),
        ("PR-2404", "Summer Sun Care", "Buy 1 Get 1 50%", 0.25, "2024-06-01", "2024-07-31", "Beauty & Skincare", "Sun Care"),
        ("PR-2405", "Back to School Immunity", "Percent Off", 0.15, "2024-08-18", "2024-09-07", "Vitamins & Supplements", None),
        ("PR-2406", "National Day Hair Care", "Percent Off", 0.23, "2024-09-18", "2024-09-25", "Personal Care", "Hair Care"),
        ("PR-2407", "White Friday Beauty", "Percent Off", 0.35, "2024-11-22", "2024-11-30", "Beauty & Skincare", None),
        ("PR-2408", "Flu Season Defense", "Percent Off", 0.15, "2024-12-01", "2024-12-31", "OTC Medicines", "Cold, Cough & Flu"),
        ("PR-2501", "New Year New You", "Percent Off", 0.20, "2025-01-01", "2025-01-31", "Vitamins & Supplements", "Manage Your Weight"),
        ("PR-2502", "Ramadan Beauty Nights", "Percent Off", 0.25, "2025-03-01", "2025-03-29", "Beauty & Skincare", None),
        ("PR-2503", "Eid Fragrance Gift", "Percent Off", 0.30, "2025-03-20", "2025-04-01", "Fragrances", None),
        ("PR-2504", "Summer Sun Care", "Buy 1 Get 1 50%", 0.25, "2025-06-01", "2025-07-31", "Beauty & Skincare", "Sun Care"),
        ("PR-2505", "Devices Week", "Percent Off", 0.20, "2025-05-10", "2025-05-17", "Medical Devices", None),
        ("PR-2506", "National Day Hair Care", "Percent Off", 0.23, "2025-09-18", "2025-09-25", "Personal Care", "Hair Care"),
        ("PR-2507", "White Friday Beauty", "Percent Off", 0.35, "2025-11-21", "2025-11-29", "Beauty & Skincare", None),
        ("PR-2508", "Private Label Launch", "Percent Off", 0.30, "2025-10-01", "2025-10-31", "Private Label", None),
    ], columns=["promo_code", "promo_name", "promo_type", "discount_pct", "start_date", "end_date",
                "target_department", "target_category"])
    promos["uplift"] = rng.uniform(1.4, 2.1, len(promos)).round(2)

    keep_p = [c for c in prod.columns if c not in ("popularity", "is_slow_mover_truth")]
    br[[c for c in br.columns if c != "traffic"]].to_csv(erp / "branches.csv", index=False)
    wh.to_csv(erp / "warehouses.csv", index=False)
    sup.drop(columns=["delay_mean", "fill_rate"]).to_csv(erp / "suppliers.csv", index=False)
    prod[keep_p].to_csv(erp / "products.csv", index=False)
    price_hist.to_csv(erp / "price_history.csv", index=False)
    emp.to_csv(erp / "employees.csv", index=False)
    promos.drop(columns=["uplift"]).to_csv(erp / "promotions.csv", index=False)
    cust.to_csv(crm / "customers.csv", index=False)
    return br, wh, sup, prod, price_hist, emp, cust, promos


# ------------------------------------------------------------------------- simulation
def simulate(rng, scale, out, br, sup, prod, price_hist, emp, cust, promos):
    cal = build_calendar()
    nD, nB, nP = len(cal), len(br), len(prod)
    dates = cal["date"].dt.date.values

    # ---- expected lines per product-branch-day
    target_lines = 165 * 1.9 * scale                     # avg invoices/day x lines/invoice at a 1.0 branch
    w = prod["popularity"].values.copy()
    chronic = prod["is_chronic"].values.astype(bool)
    w[chronic] *= 0.55                                     # part of chronic demand comes from named refills below
    w = w / w.sum() * target_lines

    mix = np.ones((nB, nP))
    for i, t in enumerate(br["branch_type"]):
        for dept, f in TYPE_MIX[t].items():
            mix[i, prod["department"].values == dept] *= f
    mix *= br["traffic"].values[:, None]

    season = np.ones((nD, nP))
    months = cal["month"].values
    for cat, curve in SEASON.items():
        m = (prod["category"].values == cat) | (prod["sub_category"].values == cat)
        season[:, m] *= np.array([curve[x] for x in months])[:, None]
    dept = prod["department"].values
    ram, pre_eid, eid = cal["is_ramadan"].values, cal["is_pre_eid"].values, cal["is_eid"].values
    season[np.ix_(pre_eid, np.isin(dept, ["Fragrances"]))] *= 2.6
    season[np.ix_(pre_eid, np.isin(dept, ["Beauty & Skincare", "Personal Care"]))] *= 1.5
    season[np.ix_(ram, prod["category"].values == "Digestive Health")] *= 1.45
    season[np.ix_(eid, prod["category"].values == "Digestive Health")] *= 1.6
    season[np.ix_(ram, np.isin(dept, ["Fragrances"]))] *= 1.3

    dow_f = np.select([cal["dow"] == 3, cal["dow"] == 4, cal["dow"] == 5], [1.12, 0.92, 1.05], 1.0)
    day_f = dow_f * np.where(eid, 0.75, 1.0) * np.where(ram, 0.95, 1.0)
    trend = 1 + 0.065 * (np.arange(nD) / 365)              # ~6.5% yearly growth
    day_f = day_f * trend * rng.normal(1, 0.04, nD)

    # promotions
    promo_idx = np.full((nD, nP), -1, dtype=np.int16)
    promo_disc = np.zeros(len(promos))
    for k, p in enumerate(promos.itertuples()):
        dmask = (cal["date"] >= p.start_date) & (cal["date"] <= p.end_date)
        if p.target_department == "Private Label":
            pmask = prod["is_private_label"].values == 1
        else:
            pmask = dept == p.target_department
            if isinstance(p.target_category, str):
                pmask &= (prod["category"].values == p.target_category) | (prod["sub_category"].values == p.target_category)
        promo_idx[np.ix_(dmask.values, pmask)] = k
        season[np.ix_(dmask.values, pmask)] *= p.uplift
        promo_disc[k] = p.discount_pct

    # ---- stockout episodes (branch-product)
    sup_info = sup.set_index("supplier_code")
    prod_sup = prod["supplier_code"].values
    hazard = np.array([{"SUP-03": 0.010, "SUP-05": 0.006, "SUP-07": 0.005}.get(s, 0.0025) for s in prod_sup])
    stock_out = np.zeros((nD, nB, nP), dtype=bool) if nD * nB * nP < 2e7 else None
    events = []
    # national shortages (whole chain): GLP-1 injectables 2024, amoxicillin suspension winter 2024/25
    national = [("SEMAGLUTIDE|LIRAGLUTIDE|DULAGLUTIDE", date(2024, 2, 1), date(2024, 5, 31)),
                ("AMOXICILLIN|CEFPROZIL", date(2024, 12, 5), date(2025, 1, 20)),
                ("OSELTAMIVIR", date(2025, 1, 10), date(2025, 2, 5))]
    sci = prod["scientific_name"].fillna("").values
    for pat, a, b in national:
        pm = np.array([any(x in s for x in pat.split("|")) for s in sci])
        da = (dates >= a) & (dates <= b)
        for bi in range(nB):
            # branches lose stock on different days as remaining units run out
            lag = int(rng.integers(0, 12))
            start_b = max(a + timedelta(days=lag), br["open_date"][bi].date())
            if start_b > b: continue
            dsub = da & (dates >= start_b)
            stock_out[np.ix_(dsub, [bi], pm)] = True
            for pi in np.where(pm)[0]:
                events.append((br["branch_code"][bi], prod["product_code"][pi], start_b, b, "National shortage"))
    open_day = ((br["open_date"] - pd.Timestamp(START)).dt.days.clip(lower=0)).values
    for bi in range(nB):
        n_ev = rng.poisson(hazard * (nD - open_day[bi]) / 6)
        for pi in np.where(n_ev > 0)[0]:
            for _ in range(n_ev[pi]):
                s = int(rng.integers(open_day[bi], nD - 3)); L = int(rng.integers(2, 21))
                stock_out[s:s + L, bi, pi] = True
                reason = "Supplier delay" if prod_sup[pi] in ("SUP-03", "SUP-07") else "Replenishment gap"
                events.append((br["branch_code"][bi], prod["product_code"][pi], dates[s], dates[min(s + L - 1, nD - 1)], reason))
    so = pd.DataFrame(events, columns=["branch_code", "product_code", "out_of_stock_from", "back_in_stock_on", "reason"])

    # ---- chronic patients (named, recurring refills)
    chronic_idx = np.where(chronic)[0]
    n_pat = int(len(cust) * 0.22)
    pat = cust.sample(n_pat, random_state=1).reset_index(drop=True)
    refills = []  # (date_idx, branch_idx, product_idx, customer_code)
    bidx = {c: i for i, c in enumerate(br["branch_code"])}
    open_idx = ((br["open_date"] - pd.Timestamp(START)).dt.days.clip(lower=0)).values
    for p in pat.itertuples():
        k = rng.choice([1, 2, 3], p=[.5, .35, .15])
        meds = rng.choice(chronic_idx, k, replace=False, p=(prod["popularity"].values[chronic_idx] / prod["popularity"].values[chronic_idx].sum()))
        b = bidx[p.home_branch_code]
        start = max(int(rng.integers(0, 60)), open_idx[b] + int(rng.integers(0, 30)))
        stop = nD if rng.random() > 0.3 else int(rng.integers(start + 30, nD + 200))   # ~30% lapse at some point
        for m in meds:
            d = start + int(rng.integers(0, 10))
            while d < min(stop, nD):
                refills.append((d, b, m, p.customer_code))
                d += int(rng.normal(30, 3)) + (int(rng.integers(5, 25)) if rng.random() < 0.12 else 0)
    ref = pd.DataFrame(refills, columns=["d", "b", "p", "customer_code"])

    # price elasticity: retail items lose ~3% volume after the +5% increase on 1 Feb 2025
    retail_mask = prod["source"].values != "SFDA drugs list"
    after = (cal["date"] >= "2025-02-01").values
    season[np.ix_(after, retail_mask)] *= 0.97

    # cross-selling rules: (trigger category, companion category, probability per basket)
    cat_arr = prod["category"].values
    AFFINITY = [("Antibiotics", "Digestive Health", 0.22), ("Cold, Cough & Flu", "Pain & Fever", 0.30),
                ("Pain & Fever", "Cold, Cough & Flu", 0.10), ("Diabetes", "Diabetic Care", 0.06),
                ("Sun Care", "Moisturizers", 0.15), ("Makeup", "Cleansers", 0.12),
                ("Fragrances For Her", "Makeup", 0.18), ("Hair Care", "Hair Vitamins", 0.08),
                ("Hypertension & Heart", "Heart Monitors", 0.03), ("Baby Care", "Kids Health", 0.12)]
    pop = prod["popularity"].values
    AFF = []
    for a, b, pr_ in AFFINITY:
        src = np.isin(cat_arr, [a]) | (prod["department"].values == a)
        tgt = np.where(cat_arr == b)[0]
        if src.any() and len(tgt):
            AFF.append((src, tgt, pop[tgt] / pop[tgt].sum(), pr_))

    # ---- prices by day (price_history)
    ph = price_hist.copy(); ph["valid_from"] = pd.to_datetime(ph["valid_from"])
    pcode_idx = {c: i for i, c in enumerate(prod["product_code"])}
    price_old = prod["list_price_sar"].values
    newp = ph[ph["valid_from"] == "2025-02-01"]
    price_new = price_old.copy()
    price_new[[pcode_idx[c] for c in newp["product_code"]]] = newp["list_price_sar"].values
    switch_d = (pd.Timestamp("2025-02-01") - pd.Timestamp(START)).days

    # staff per branch for cashier assignment
    staff = {b: emp[(emp["branch_code"] == b)] for b in br["branch_code"]}
    cust_by_branch = cust.groupby("home_branch_code")["customer_code"].apply(np.array).to_dict()
    is_rx = prod["is_rx"].values.astype(bool)
    pos = out / "pos"; pos.mkdir(parents=True, exist_ok=True)

    inv_seq = 0
    month_rows, cur_month = [], None
    daily_sales = np.zeros((nD, nB, nP), dtype=np.float32)
    ref_groups = ref.groupby(["d", "b"]) if len(ref) else {}
    ref_dict = {k: v for k, v in ref_groups} if len(ref) else {}

    def flush(rows, ym):
        if not rows: return
        df = pd.concat(rows, ignore_index=True)
        df.to_csv(pos / f"sales_lines_{ym}.csv", index=False)

    for d in range(nD):
        ym = cal["date"][d].strftime("%Y_%m")
        if ym != cur_month:
            flush(month_rows, cur_month); month_rows, cur_month = [], ym
        hourp = HOUR_RAMADAN if ram[d] else HOUR_FRIDAY if cal["dow"][d] == 4 else HOUR_NORMAL
        prices = price_new if d >= switch_d else price_old
        for b in range(nB):
            if d < open_idx[b]:
                continue
            ramp = min(1.0, 0.35 + (d - open_idx[b]) / 240) if open_idx[b] > 0 else 1.0   # new branch ramp-up
            lam = w * mix[b] * season[d] * day_f[d] * ramp
            n = rng.poisson(lam)
            if stock_out is not None:
                n[stock_out[d, b]] = 0
            lines_p = np.repeat(np.arange(nP), n)
            # named chronic refills (lost if out of stock that day)
            r = ref_dict.get((d, b))
            ref_p = r["p"].values if r is not None else np.array([], dtype=int)
            ref_c = r["customer_code"].values if r is not None else np.array([], dtype=object)
            if stock_out is not None and len(ref_p):
                ok = ~stock_out[d, b, ref_p]; ref_p, ref_c = ref_p[ok], ref_c[ok]
            if len(lines_p) == 0 and len(ref_p) == 0:
                continue
            rng.shuffle(lines_p)
            # basket sizes
            sizes = 1 + rng.geometric(0.55, size=len(lines_p)) - 1
            if len(lines_p):
                cs = np.cumsum(sizes); k = np.searchsorted(cs, len(lines_p)) + 1
                inv_of_line = np.repeat(np.arange(k), sizes[:k])[:len(lines_p)]
            else:                                     # only chronic refills today
                k, inv_of_line = 0, np.array([], dtype=int)
            # companion items (cross-selling) added to the same basket
            add_p, add_inv = [], []
            for src, tgt, tp, pr_ in AFF:
                inv_hit = np.unique(inv_of_line[src[lines_p]])
                if not len(inv_hit): continue
                inv_hit = inv_hit[rng.random(len(inv_hit)) < pr_]
                if len(inv_hit):
                    add_inv.append(inv_hit); add_p.append(rng.choice(tgt, len(inv_hit), p=tp))
            if add_p:
                lines_p = np.concatenate([lines_p] + add_p)
                inv_of_line = np.concatenate([inv_of_line] + add_inv)
            n_inv = k
            # each refill patient is one invoice (meds of the same patient grouped)
            if len(ref_p):
                uc, ref_inv = np.unique(ref_c, return_inverse=True)
                ref_inv = ref_inv + n_inv
                n_inv += len(uc)
                all_p = np.concatenate([lines_p, ref_p]); all_inv = np.concatenate([inv_of_line, ref_inv])
                inv_cust = np.concatenate([np.full(k, None, dtype=object), uc])
            else:
                all_p, all_inv = lines_p, inv_of_line
                inv_cust = np.full(k, None, dtype=object)
            # loyalty customer on ~32% of walk-in invoices
            pool = cust_by_branch.get(br["branch_code"][b])
            if pool is not None and len(pool):
                m = rng.random(k) < 0.32
                inv_cust[:k][m] = rng.choice(pool, m.sum())
            hr = rng.choice(HOURS, size=n_inv, p=hourp / hourp.sum())
            if not br["is_24h"][b]:
                hr = np.where((hr >= 1) & (hr < 8), rng.choice([8, 9, 23, 0], n_inv), hr)
            mins = rng.integers(0, 60, n_inv); secs = rng.integers(0, 60, n_inv)
            inv_has_rx = np.zeros(n_inv, bool); np.logical_or.at(inv_has_rx, all_inv, is_rx[all_p])
            pay = np.where(inv_has_rx, rng.choice(["Insurance", "Card", "Cash"], n_inv, p=[.55, .35, .10]),
                           rng.choice(["Card", "Cash", "BNPL"], n_inv, p=[.76, .19, .05]))
            st = staff[br["branch_code"][b]]
            # prescriptions are dispensed by a pharmacist; anyone can ring up a non-Rx basket
            rph = st[st["job_title"] != "Pharmacy Assistant"]["employee_code"].values
            cashier = np.where(inv_has_rx, rng.choice(rph, n_inv), rng.choice(st["employee_code"].values, n_inv))
            qty = np.where(chronic[all_p], rng.choice([1, 2, 3], len(all_p), p=[.6, .3, .1]),
                           rng.choice([1, 2, 3], len(all_p), p=[.84, .13, .03]))
            # the same product scanned twice in one invoice becomes one line with the summed quantity
            key = all_inv.astype(np.int64) * nP + all_p
            _, first, inverse = np.unique(key, return_index=True, return_inverse=True)
            qty = np.bincount(inverse, weights=qty).astype(int)
            all_p, all_inv = all_p[first], all_inv[first]
            pk = promo_idx[d, all_p]
            disc_pct = np.where(pk >= 0, promo_disc[np.maximum(pk, 0)], 0.0)
            unit = prices[all_p]
            inv_no = inv_seq + all_inv
            inv_seq += n_inv
            ts = pd.Timestamp(dates[d]) + pd.to_timedelta(hr[all_inv], unit="h") \
                 + pd.to_timedelta(mins[all_inv], unit="m") + pd.to_timedelta(secs[all_inv], unit="s")
            # invoices in the 00-02 window of a non-24h store belong to the previous business day; keep calendar time
            df = pd.DataFrame({
                "invoice_no": [f"{br['branch_code'][b]}-{x:09d}" for x in inv_no],
                "invoice_ts": ts,
                "branch_code": br["branch_code"][b],
                "cashier_code": cashier[all_inv],
                "customer_code": inv_cust[all_inv],
                "payment_type": pay[all_inv],
                "product_code": prod["product_code"].values[all_p],
                "qty": qty,
                "unit_price": unit,
                "discount_amount": np.round(unit * qty * disc_pct, 2),
                "promo_code": np.where(pk >= 0, promos["promo_code"].values[np.maximum(pk, 0)], None),
            })
            np.add.at(daily_sales[d, b], all_p, qty)
            month_rows.append(df)
    flush(month_rows, cur_month)
    so.to_csv(out / "wms" / "stockout_events.csv", index=False) if (out / "wms").exists() else None
    return cal, daily_sales, so, stock_out


def supply_chain(rng, out, cal, daily_sales, br, sup, prod, stock_out):
    wms, erp = out / "wms", out / "erp"
    wms.mkdir(parents=True, exist_ok=True)
    nD, nB, nP = daily_sales.shape
    dates = cal["date"].dt.date.values
    supi = sup.set_index("supplier_code")
    prod_sup = prod["supplier_code"].values
    br_wh = br["warehouse_code"].values
    shelf = prod["shelf_life_months"].values
    cost = prod["unit_cost_sar"].values

    # ---- weekly DC -> branch transfers (every Sunday, previous week's sales + small buffer)
    tr = []
    t_no = 1
    for d in range(6, nD, 7):
        wk = daily_sales[d - 6:d + 1].sum(axis=0)           # (nB, nP)
        for b in range(nB):
            need = np.ceil(wk[b] * rng.uniform(0.95, 1.15, nP))
            idx = np.where(need > 0)[0]
            if not len(idx): continue
            # most lines ship complete; ~12% are short by a few units; nothing ships for items the DC is out of
            short = rng.random(len(idx)) < 0.12
            shipped = need[idx] - np.where(short, np.minimum(need[idx], rng.integers(1, 4, len(idx))), 0)
            if stock_out is not None:
                shipped[stock_out[min(d + 1, nD - 1), b, idx]] = 0
            tr.append(pd.DataFrame({"transfer_no": f"TR-{t_no:07d}", "warehouse_code": br_wh[b],
                                    "branch_code": br["branch_code"][b], "request_date": dates[d],
                                    "ship_date": dates[min(d + 1, nD - 1)], "product_code": prod["product_code"].values[idx],
                                    "qty_requested": need[idx].astype(int), "qty_shipped": shipped.astype(int)}))
            t_no += 1
    pd.concat(tr).to_csv(wms / "transfers_to_branches.csv", index=False)

    # ---- purchase orders: every 14 days per supplier per DC
    po = []
    po_no = 1
    for d in range(0, nD, 14):
        # order the next 14 days of demand, estimated from the last 28 days
        horizon = daily_sales[max(0, d - 28):d + 1].sum(axis=0) / max(1, min(28, d + 1)) * 14 if d > 0 else daily_sales[:14].sum(axis=0)
        for whc in ("DC-RUH", "DC-JED"):
            demand = horizon[br_wh == whc].sum(axis=0)
            for s in sup.itertuples():
                idx = np.where((prod_sup == s.supplier_code) & (demand > 0))[0]
                if not len(idx): continue
                si = supi.loc[s.supplier_code]
                qty = np.ceil(demand[idx] * rng.uniform(0.95, 1.12, len(idx)) / 6) * 6   # case packs of 6
                delay = max(0, int(rng.poisson(si.delay_mean)))
                expected = d + int(si.agreed_lead_days)
                received = expected + delay
                fill = np.where(rng.random(len(idx)) < si.fill_rate, 1.0, rng.uniform(0.5, 0.95, len(idx)))
                if stock_out is not None:
                    short = stock_out[min(received, nD - 1)].mean(axis=0)[idx] > 0.5   # national shortage: little arrives
                    fill[short] *= 0.25
                rec_q = np.floor(qty * fill)
                infl = {"SUP-07": 1.065, "SUP-06": 1.045, "SUP-03": 1.05, "SUP-05": 1.035, "SUP-09": 1.0}.get(s.supplier_code, 1.02)
                cst = cost[idx] * (infl if dates[d] >= date(2025, 2, 1) else 1.0) * rng.uniform(0.99, 1.01, len(idx))
                status = "Received" if received < nD else "Open"
                po.append(pd.DataFrame({
                    "po_no": f"PO-{dates[d]:%y}{po_no:05d}", "supplier_code": s.supplier_code, "warehouse_code": whc,
                    "order_date": dates[d], "expected_date": dates[min(expected, nD - 1)] if expected < nD else dates[d] + timedelta(days=int(si.agreed_lead_days)),
                    "received_date": dates[received] if received < nD else None,
                    "product_code": prod["product_code"].values[idx], "qty_ordered": qty.astype(int),
                    "qty_received": np.where(received < nD, rec_q, 0).astype(int), "unit_cost": cst.round(2),
                    "status": status}))
                po_no += 1
    po_df = pd.concat(po, ignore_index=True)
    po_df.to_csv(erp / "purchase_orders.csv", index=False)

    # ---- month-end inventory snapshot (branches + DCs)
    me = []
    month_end = cal.groupby([cal["year"], cal["month"]])["date"].max().dt.date.values
    avg30 = {}
    for m_end in month_end:
        d = int(np.where(dates == m_end)[0][0])
        a = daily_sales[max(0, d - 29):d + 1].mean(axis=0)   # (nB,nP)
        cover = rng.uniform(12, 40, (nB, nP))
        cover[:, prod["is_slow_mover_truth"].values == 1] = rng.uniform(120, 400, (nB, (prod["is_slow_mover_truth"] == 1).sum()))
        oh = np.round(a * cover + rng.integers(0, 3, (nB, nP)))
        oh[a == 0] = rng.integers(0, 4, (a == 0).sum())
        if stock_out is not None:
            oh[stock_out[d]] = 0
        for b in range(nB):
            if pd.Timestamp(m_end) < br["open_date"][b]: continue
            idx = np.where(oh[b] > 0)[0]
            me.append(pd.DataFrame({"snapshot_date": m_end, "location_code": br["branch_code"][b],
                                    "product_code": prod["product_code"].values[idx], "qty_on_hand": oh[b, idx].astype(int)}))
        for whc in ("DC-RUH", "DC-JED"):
            dc = np.round(a[br_wh == whc].sum(axis=0) * rng.uniform(15, 35, nP))
            idx = np.where(dc > 0)[0]
            me.append(pd.DataFrame({"snapshot_date": m_end, "location_code": whc,
                                    "product_code": prod["product_code"].values[idx], "qty_on_hand": dc[idx].astype(int)}))
        avg30[m_end] = a
    me_df = pd.concat(me, ignore_index=True)
    me_df.to_csv(wms / "inventory_month_end.csv", index=False)

    # ---- batches on hand at the snapshot date (expiry analysis)
    last = me_df[me_df["snapshot_date"] == SNAPSHOT].copy()
    pidx = {c: i for i, c in enumerate(prod["product_code"])}
    pi = last["product_code"].map(pidx).values
    slow = prod["is_slow_mover_truth"].values[pi] == 1
    rows = []
    for (loc, pc, q), p_i, s in zip(last[["location_code", "product_code", "qty_on_hand"]].itertuples(index=False), pi, slow):
        nb = 1 if q < 4 else int(rng.integers(1, 4))
        split = rng.multinomial(q, np.ones(nb) / nb)
        for j, qq in enumerate(split):
            if qq == 0: continue
            age_days = int(rng.integers(20, 200) if not s else rng.integers(200, 30 * shelf[p_i] + 60))
            received = SNAPSHOT - timedelta(days=age_days)
            expiry = received + timedelta(days=int(30.4 * shelf[p_i]))
            rows.append((loc, pc, f"B{pc[1:]}{received:%y%m}{j}", received, expiry, int(qq)))
    bt = pd.DataFrame(rows, columns=["location_code", "product_code", "batch_no", "received_date", "expiry_date", "qty_on_hand"])
    bt.to_csv(wms / "batches_current.csv", index=False)

    # ---- expiry write-offs during the two years (slow movers + short shelf life + cold chain breaches)
    wo = []
    for m_end in month_end:
        a = avg30[m_end]
        risk = (prod["is_slow_mover_truth"].values == 1) * 0.12 + (prod["shelf_life_months"].values <= 18) * 0.03
        for b in range(nB):
            if pd.Timestamp(m_end) < br["open_date"][b]: continue
            hit = rng.random(nP) < risk * 0.6
            for p_i in np.where(hit)[0]:
                # roughly 2-6 weeks of that item's sales expire, never less than one unit
                q = int(a[b, p_i] * rng.uniform(14, 45)) + int(rng.integers(1, 6))
                wo.append((m_end, br["branch_code"][b], prod["product_code"][p_i], q, "Expired"))
    # two cold-chain breaches (fridge failures)
    for when, loc in [(date(2024, 7, 14), "JED-005"), (date(2025, 8, 3), "RUH-007")]:
        for p_i in np.where(prod["is_cold_chain"].values == 1)[0]:
            wo.append((when, loc, prod["product_code"][p_i], int(rng.integers(3, 15)), "Cold chain breach"))
    pd.DataFrame(wo, columns=["writeoff_date", "location_code", "product_code", "qty", "reason"]).to_csv(wms / "expiry_writeoffs.csv", index=False)


def add_dirty_data(rng, out):
    """Typical source-system problems, fixed later by the staging / cleaning SQL."""
    pos = sorted((out / "pos").glob("sales_lines_*.csv"))
    for f in pos[::5]:
        df = pd.read_csv(f, parse_dates=["invoice_ts"], low_memory=False)
        dup = df.sample(frac=0.0007, random_state=3)                       # duplicated POS uploads
        ret = df.sample(frac=0.004, random_state=4).copy()                 # customer returns
        ret["qty"] = -ret["qty"]; ret["invoice_no"] = ret["invoice_no"] + "-R"
        ret["invoice_ts"] = ret["invoice_ts"] + pd.Timedelta(days=2)
        messy = df.sample(frac=0.002, random_state=5).index                 # lowercase / padded codes
        df.loc[messy, "product_code"] = " " + df.loc[messy, "product_code"].str.lower() + " "
        df = pd.concat([df, dup, ret]).sort_values("invoice_ts")
        df.to_csv(f, index=False)
    po = pd.read_csv(out / "erp" / "purchase_orders.csv", dtype=str)
    bad = po.sample(12, random_state=6).index                               # received before ordered (typo)
    po.loc[bad, "received_date"] = (pd.to_datetime(po.loc[bad, "order_date"]) - pd.Timedelta(days=3)).dt.date.astype(str)
    po.to_csv(out / "erp" / "purchase_orders.csv", index=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", type=float, default=0.5)
    ap.add_argument("--out", default=str(ROOT / "data" / "generated"))
    ap.add_argument("--seed", type=int, default=2026)
    a = ap.parse_args()
    out = Path(a.out); (out / "wms").mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    br, wh, sup, prod, ph, emp, cust, promos = make_masters(rng, a.scale, out)
    print("masters:", len(br), "branches,", len(prod), "products,", len(emp), "employees,", len(cust), "customers")
    sup_full = pd.DataFrame(SUPPLIERS, columns=["supplier_code", "supplier_name", "supplier_type", "city",
                                                "agreed_lead_days", "delay_mean", "fill_rate", "payment_terms_days"])
    cal, daily, so, stock_out = simulate(rng, a.scale, out, br, sup_full, prod, ph, emp, cust, promos)
    so.to_csv(out / "wms" / "stockout_events.csv", index=False)
    print("sales simulated; stockout events:", len(so))
    supply_chain(rng, out, cal, daily, br, sup_full, prod, stock_out)
    add_dirty_data(rng, out)
    print("done ->", out)


if __name__ == "__main__":
    main()
