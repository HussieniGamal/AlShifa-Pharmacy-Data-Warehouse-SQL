/* =============================================================================
   10  Mart views for Power BI
   -----------------------------------------------------------------------------
   Business-friendly names, no surrogate-key gymnastics for report authors.
   Import these views into Power BI (or connect in DirectQuery) and build the
   relationships on the *_key columns.
   ============================================================================= */
USE AlShifaDW;
GO

-- Q1. Calendar
CREATE OR ALTER VIEW mart.v_calendar AS
SELECT date_key, full_date AS [date], [year], [quarter], [month], month_name, year_month,
       day_name, day_of_week_sat1, is_weekend, is_ramadan, is_eid, is_public_holiday, season
FROM dw.dim_date
WHERE [year] BETWEEN 2024 AND 2025;
GO

-- Q2. Branches and warehouses
CREATE OR ALTER VIEW mart.v_location AS
SELECT location_key, location_code, location_name, location_type, city, region, district, branch_type,
       size_sqm, is_24h, open_date,
       CASE WHEN open_date < '2024-01-01' THEN 'Like-for-like' ELSE 'New 2025' END AS lfl_group
FROM dw.dim_location;
GO

-- Q3. Products
CREATE OR ALTER VIEW mart.v_product AS
SELECT p.product_key, p.product_code, p.product_name, p.brand, p.department, p.category, p.sub_category,
       p.therapeutic_class, p.scientific_name, p.dosage_form,
       CASE WHEN p.is_rx = 1 THEN 'Prescription' ELSE 'Non-prescription' END AS rx_status,
       CASE WHEN p.is_chronic = 1 THEN 'Chronic' ELSE 'Acute / other' END     AS chronic_status,
       p.is_cold_chain, p.is_private_label, p.current_list_price, p.current_unit_cost,
       s.supplier_name
FROM dw.dim_product p
JOIN dw.dim_supplier s ON s.supplier_key = p.supplier_key;
GO

-- Q4. Sales lines
CREATE OR ALTER VIEW mart.v_sales AS
SELECT f.invoice_no, f.line_type, f.date_key, f.hour_of_day, f.location_key, f.product_key,
       f.customer_key, f.employee_key, f.promotion_key, f.payment_type,
       CASE WHEN f.customer_key = -1 THEN 'Walk-in' ELSE 'Loyalty member' END AS customer_type,
       f.qty, f.gross_amount, f.discount_amount, f.net_amount, f.cost_amount,
       f.net_amount - f.cost_amount AS gross_profit
FROM dw.fact_sales f;
GO

-- Q5. Supplier delivery performance (PO line grain)
CREATE OR ALTER VIEW mart.v_purchase_order_line AS
SELECT f.po_no, f.supplier_key, s.supplier_name, f.location_key AS warehouse_key, f.product_key,
       f.order_date_key, f.expected_date_key, f.received_date_key, f.qty_ordered, f.qty_received,
       f.order_value, f.received_value, f.lead_time_days, f.delay_days, f.is_on_time, f.is_in_full,
       CASE WHEN f.is_on_time = 1 AND f.is_in_full = 1 THEN 1 ELSE 0 END AS is_otif,
       f.po_status
FROM dw.fact_purchase_order_line f
JOIN dw.dim_supplier s ON s.supplier_key = f.supplier_key
WHERE f.dq_issue IS NULL;
GO

-- Q6. Month-end inventory with 30-day sales velocity and days of cover
CREATE OR ALTER VIEW mart.v_inventory_month_end AS
WITH v AS (
    SELECT d.year_month, f.location_key, f.product_key, SUM(f.qty) AS units_sold_in_month
    FROM dw.fact_sales f
    JOIN dw.dim_date d ON d.date_key = f.date_key
    GROUP BY d.year_month, f.location_key, f.product_key
)
SELECT i.snapshot_date_key, i.location_key, i.product_key, i.qty_on_hand, i.stock_value,
       COALESCE(v.units_sold_in_month, 0) AS units_sold_in_month,
       CASE WHEN COALESCE(v.units_sold_in_month, 0) = 0 THEN NULL
            ELSE 30.0 * i.qty_on_hand / v.units_sold_in_month END AS days_of_cover
FROM dw.fact_inventory_month_end i
JOIN dw.dim_date d ON d.date_key = i.snapshot_date_key
LEFT JOIN v ON v.year_month = d.year_month AND v.location_key = i.location_key AND v.product_key = i.product_key;
GO

-- Q7. Batches on hand at the snapshot with an expiry bucket
CREATE OR ALTER VIEW mart.v_expiry_risk AS
SELECT b.location_key, b.product_key, b.batch_no, b.expiry_date, b.qty_on_hand, b.stock_value, b.days_to_expiry,
       CASE WHEN b.days_to_expiry < 0   THEN '0. Expired'
            WHEN b.days_to_expiry <= 90  THEN '1. 0-90 days'
            WHEN b.days_to_expiry <= 180 THEN '2. 91-180 days'
            WHEN b.days_to_expiry <= 365 THEN '3. 181-365 days'
            ELSE '4. Over 1 year' END AS expiry_bucket
FROM dw.fact_inventory_batch b;
GO

-- Q8. Stock-outs with estimated lost sales
CREATE OR ALTER VIEW mart.v_stockout AS
WITH r AS (
    SELECT location_key, product_key, SUM(net_amount) / 731.0 AS sales_per_day
    FROM dw.fact_sales
    GROUP BY location_key, product_key
)
SELECT e.location_key, e.product_key, e.start_date_key, e.end_date_key, e.days_out, e.reason,
       e.days_out * COALESCE(r.sales_per_day, 0) AS est_lost_sales
FROM dw.fact_stockout_event e
LEFT JOIN r ON r.location_key = e.location_key AND r.product_key = e.product_key;
GO

-- Q9. Smoke test: every view returns rows
SELECT 'v_calendar' AS view_name, COUNT(*) AS row_count FROM mart.v_calendar
UNION ALL SELECT 'v_location', COUNT(*) FROM mart.v_location
UNION ALL SELECT 'v_product', COUNT(*) FROM mart.v_product
UNION ALL SELECT 'v_sales', COUNT(*) FROM mart.v_sales
UNION ALL SELECT 'v_purchase_order_line', COUNT(*) FROM mart.v_purchase_order_line
UNION ALL SELECT 'v_inventory_month_end', COUNT(*) FROM mart.v_inventory_month_end
UNION ALL SELECT 'v_expiry_risk', COUNT(*) FROM mart.v_expiry_risk
UNION ALL SELECT 'v_stockout', COUNT(*) FROM mart.v_stockout;
