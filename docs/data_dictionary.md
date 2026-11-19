# Data dictionary

Grain, keys and business meaning of every table in the `dw` schema.
Surrogate keys are `INT IDENTITY`. Unknown members use key `-1` (walk-in customer, no promotion, unknown employee).

## Dimensions (conformed: shared by every department)

| Table | Grain | Key columns | Notes |
|---|---|---|---|
| `dim_date` | one row per calendar day 2023-2026 | `date_key` (yyyymmdd) | Saudi week (`day_of_week_sat1`: Sat = 1), weekend = Fri + Sat, `is_ramadan`, `is_eid`, `is_public_holiday` from `ref.calendar_event` |
| `dim_location` | one row per branch or distribution center | `location_key`, `location_code` | 35 branches + 2 DCs. `branch_type` = Street, Residential, Mall, Hospital, Highway. `open_date` drives like-for-like analysis |
| `dim_product` | one row per sellable item | `product_key`, `product_code` | 622 items. Department > category > sub-category. Flags: `is_rx`, `is_chronic`, `is_cold_chain`, `is_private_label`. `data_source` shows where the item and its price came from |
| `dim_product_price` | one row per product per price-list period | `product_key` + `valid_from` | Validity ranges (type-2 style). Every sale is costed with the row valid on the sale date |
| `dim_supplier` | one row per supplier | `supplier_key`, `supplier_code` | Agreed lead time and payment terms |
| `dim_employee` | one row per employee | `employee_key`, `employee_code` | Phase 1: branch and area staff. `manager_code` holds the reporting line |
| `dim_customer` | one row per loyalty member | `customer_key`, `customer_code` | Age band, home branch, tier, insurance flag |
| `dim_promotion` | one row per campaign | `promotion_key`, `promo_code` | Discount %, dates, target department / category |

## Facts (one per business process)

| Table | Owner | Grain | Measures |
|---|---|---|---|
| `fact_sales` | Sales | one invoice line | `qty`, `gross_amount`, `discount_amount`, `net_amount`, `cost_amount`. Returns are negative lines with `line_type = 'Return'` |
| `fact_purchase_order_line` | Purchasing | one PO line | ordered vs. received qty and value, `lead_time_days`, `delay_days`, `is_on_time`, `is_in_full`, `dq_issue` |
| `fact_branch_transfer` | Warehouse | one DC-to-branch transfer line | `qty_requested`, `qty_shipped` |
| `fact_inventory_month_end` | Warehouse | location x product x month-end | `qty_on_hand`, `stock_value` (periodic snapshot) |
| `fact_inventory_batch` | Warehouse / Quality | location x product x batch on 31 Dec 2025 | `qty_on_hand`, `expiry_date`, `days_to_expiry` |
| `fact_stockout_event` | Supply chain | one out-of-stock episode per branch and product | `days_out`, `reason` (Replenishment gap, Supplier delay, National shortage) |
| `fact_writeoff` | Warehouse / Quality | one write-off record | `qty`, `cost_value`, `reason` (Expired, Cold chain breach) |

## Staging (`stg`) and source systems

| Source system | Extract | Staging table |
|---|---|---|
| ERP | branches, warehouses, suppliers, products, price history, employees, promotions, purchase orders | `stg.erp_*` |
| POS | sales lines, one CSV per month | `stg.pos_sales_lines` |
| CRM | loyalty customers | `stg.crm_customers` |
| WMS | transfers, month-end inventory, current batches, write-offs, stock-out log | `stg.wms_*` |

All staging columns are `NVARCHAR`: the load procedures trim, upper-case, `TRY_CAST` and validate.

## Where the data comes from

* **Drug names, strengths and prices**: the public drugs list of the Saudi Food & Drug Authority (sfda.gov.sa), 395 items after filtering to community-pharmacy molecules.
* **Beauty, care, vitamin and device items with shelf prices**: a public Saudi pharmacy retail website (reference prices only).
* **Al Shifa private label**: 15 invented items.
* **Everything else** (branches, staff, customers, transactions, suppliers, stock) is simulated by `scripts/generate_data.py`. The chain, its suppliers and its people are fictional.
