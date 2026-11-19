# Findings: Phase 1 (Sales, Category Management, Purchasing, Warehouse)

Data: 35 branches, 2 distribution centers, 622 products, 9.3 M sales lines, Jan 2024 to Dec 2025.
Every number below comes from a query in `sql/06` to `sql/09`. Full outputs are in [`results/`](results/).

> The chain and its transactions are simulated (see the README). Drug names and prices are real
> SFDA reference data; the behaviour patterns were designed from first-hand pharmacy operations experience.

---

## 1. Sales (`06_sales_analysis.sql`)

| KPI | 2024 | 2025 | Change |
|---|---:|---:|---:|
| Net sales | 256.2 M SAR | 279.4 M SAR | **+9.1 %** |
| Like-for-like (32 branches open both years) | 256.2 M | 269.4 M | **+5.2 %** |
| Gross margin | 28.0 % | 28.8 % | +0.8 pts |
| Average basket | 105.0 SAR | 108.8 SAR | +3.6 % |

* **Growth is mostly real, not just new stores.** 5.2 points of the 9.1 % growth come from existing branches; the three 2025 openings added 10.1 M SAR.
* **Mall branches lead on sales per day** (the top 4 are all malls, about 34-37 K SAR/day), but **hospital branches make the most per square metre** (up to 78.6 K SAR/sqm) at the lowest margin (26.5 %) because they are prescription-heavy.
* **Ramadan moves the whole day.** Peak hour shifts to 22:00 with 927 invoices/hour chain-wide (vs. 575 at the same hour on a normal day, and 38 % above the normal-day peak at 21:00), and midnight is 4x busier. Staff rosters need a night-shift plan for 30 days a year.
* **Friday mornings collapse** (09:00-13:00 about 65 % below a normal day) and Friday evenings run about 17 % above normal.
* **Fragrance sales more than double in Ramadan (+115 % per day)**; beauty is +20 %, vitamins -11 %.
* **Insurance share is 44.6 % in hospital branches vs. 29.4 % in malls**, so hospital branches carry the biggest receivables exposure.
* **New branches ramp very differently**: the Khobar mall branch passed 80 % of a mature branch in week 4, the Riyadh residential branch took 24 weeks, and the Jeddah residential branch is still at 69 % after 31 weeks, which makes it a candidate for a local marketing review.

## 2. Category management (`07_category_management.sql`)

* **Prescriptions are 45 % of sales but only 34 % of gross profit** (21.6 % margin). Vitamins, beauty and personal care earn 35-38 % margins: every point of mix shifted towards them lifts profit.
* **ABC: 36 % of items bring 80 % of revenue, while the bottom 36 % bring only 5 %.** That tail is the place to cut range and free cash.
* **Most promotions bought volume, not profit.** Unit uplift ranged from +41 % to +352 %, yet profit per day fell in 12 of the 15 campaigns that have a clean "before" period. White Friday at 35 % off cut daily profit by 78-79 % in both years. The 15 % "Flu Season Defense" doubled volume and kept profit flat, and the private-label launch was the only 30 % campaign that grew profit (+4.8 %). **Recommendation: cap routine discounts near 15-20 % and reserve deep discounts for clearing near-expiry or slow stock.**
* **The +5 % retail price increase (Feb 2025) cost little volume.** Retail units grew 1.4 points less than regulated medicines (the control group), while retail revenue still grew 7.5 % year on year.
* **Cross-selling opportunities**: baskets with Baby & Mother items are 1.66x more likely than chance to include vitamins, and Beauty + Fragrance has a lift of 1.35. These pairs are good candidates for joint placement and bundles.
* **Seasonality to plan stock around**: Sun care sells 7x more in July than in January (index 245 vs. 35), cold & flu peaks in December (221) and weight management in January (238).
* **19 items hold more than a year of stock** at the Q4 selling pace (e.g. a glucose meter with 406 days of cover, worth 37.8 K SAR).

## 3. Purchasing & suppliers (`08_purchasing_and_suppliers.sql`)

* **OTIF (on time, in full) ranges from 60 % to under 3 %.** Gulf Medical Distribution leads (60 %). Najd Healthcare Trading delivers in 9.3 days on average against an agreed 5, with only 2.6 % OTIF.
* **Weak suppliers reach the shelf**: items supplied by Najd spent **4x more days out of stock** than the chain average (1,269 vs. about 300 stock-out days per 100 items per branch).
* **Cost inflation is concentrated**: Desert Rose Fragrances +6.1 %, Najd +4.7 %, Al Waha Beauty +4.2 %, compared with about 1.8 % for the main pharma distributors (same products, both years).
* **Two suppliers hold 47 % of spend**: good for negotiation, but a concentration risk.
* After moving to a 14-day ordering cycle, purchases track sales closely (received units are 102-107 % of units sold by department).

## 4. Warehouse & inventory (`09_warehouse_and_inventory.sql`)

* **DC service level is about 97 % of units**, but only about 88 % of transfer lines arrive complete: branches feel the 12 %.
* **Stock-outs cost an estimated 5.8 M SAR of sales over two years**; half of it (2.9 M) came from three national shortages (GLP-1 injectables in 2024, amoxicillin suspension, oseltamivir) that lasted up to 115 days per branch.
* **Expiry risk at year-end**: 54 K SAR of stock is already expired and still on the shelf (a compliance issue), and 114 K SAR expires within 90 days. The query recommends a transfer or a markdown for every near-expiry batch.
* **Write-offs** reached 875 K SAR over two years (0.23 % of cost of goods), including two cold-chain fridge failures.
* Days of inventory are about 50-64 by department, highest in fragrances.

## 5. Data quality (`05_data_quality_checks.sql`)

Found and fixed by the load procedures, and reconciled line by line:

| Issue | Rows |
|---|---:|
| Duplicate POS lines (same line uploaded twice) | 1,341 |
| Product codes with spaces or lower case | 3,829 |
| Returns (negative quantity, kept as `Return`) | 7,659 |
| PO lines received before they were ordered (flagged, excluded from KPIs) | 12 |
| Batches past expiry still on hand | 181 |
| Sales below cost (all from deep promotions) | 586 |
