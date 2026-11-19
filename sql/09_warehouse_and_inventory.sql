/* =============================================================================
   09  Warehouse & inventory analysis
   -----------------------------------------------------------------------------
   Business owner : Supply Chain / Warehouse Manager
   Questions      : Are branches getting what they ask for, how much cash sits
                    on the shelves, what will expire, and what do stock-outs cost?
   ============================================================================= */
USE AlShifaDW;
GO

-- Q1. DC service level to branches: fill rate by warehouse and quarter
SELECT w.location_code AS warehouse,
       CONCAT(d.[year], '-Q', d.[quarter])                                     AS year_quarter,
       COUNT(DISTINCT t.transfer_no)                                           AS transfers,
       SUM(t.qty_requested)                                                    AS units_requested,
       CAST(100.0 * SUM(t.qty_shipped) / SUM(t.qty_requested) AS DECIMAL(5,1)) AS unit_fill_rate_pct,
       CAST(100.0 * AVG(CASE WHEN t.qty_shipped >= t.qty_requested THEN 1.0 ELSE 0 END) AS DECIMAL(5,1)) AS lines_complete_pct
FROM dw.fact_branch_transfer t
JOIN dw.dim_location w ON w.location_key = t.from_location_key
JOIN dw.dim_date d     ON d.date_key = t.request_date_key
GROUP BY w.location_code, CONCAT(d.[year], '-Q', d.[quarter])
ORDER BY warehouse, year_quarter;

-- Q2. Cash in stock: inventory value and days of inventory (DIO) by department at year-end
WITH stock AS (
    SELECT p.department, SUM(i.stock_value) AS stock_value
    FROM dw.fact_inventory_month_end i
    JOIN dw.dim_product p ON p.product_key = i.product_key
    WHERE i.snapshot_date_key = 20251231
    GROUP BY p.department
),
cogs AS (
    SELECT p.department, SUM(f.cost_amount) / 92.0 AS daily_cogs     -- Q4 2025 = 92 days
    FROM dw.fact_sales f
    JOIN dw.dim_product p ON p.product_key = f.product_key
    WHERE f.date_key BETWEEN 20251001 AND 20251231
    GROUP BY p.department
)
SELECT s.department,
       CAST(s.stock_value / 1e3 AS DECIMAL(12,0))                         AS stock_value_k_sar,
       CAST(100.0 * s.stock_value / SUM(s.stock_value) OVER () AS DECIMAL(5,1)) AS share_pct,
       CAST(s.stock_value / c.daily_cogs AS DECIMAL(6,0))                  AS days_of_inventory
FROM stock s
JOIN cogs c ON c.department = s.department
ORDER BY days_of_inventory DESC;

-- Q3. Expiry risk: stock expiring within 90 / 180 days at the snapshot (31 Dec 2025)
SELECT CASE WHEN b.days_to_expiry < 0   THEN '0. Already expired'
            WHEN b.days_to_expiry <= 90  THEN '1. 0-90 days'
            WHEN b.days_to_expiry <= 180 THEN '2. 91-180 days'
            WHEN b.days_to_expiry <= 365 THEN '3. 181-365 days'
            ELSE '4. Over 1 year' END                                      AS expiry_bucket,
       COUNT(*)                                                            AS batches,
       SUM(b.qty_on_hand)                                                  AS units,
       CAST(SUM(b.stock_value) / 1e3 AS DECIMAL(12,1))                     AS value_k_sar,
       CAST(100.0 * SUM(b.stock_value) / SUM(SUM(b.stock_value)) OVER () AS DECIMAL(5,1)) AS pct_of_value
FROM dw.fact_inventory_batch b
GROUP BY CASE WHEN b.days_to_expiry < 0   THEN '0. Already expired'
              WHEN b.days_to_expiry <= 90  THEN '1. 0-90 days'
              WHEN b.days_to_expiry <= 180 THEN '2. 91-180 days'
              WHEN b.days_to_expiry <= 365 THEN '3. 181-365 days'
              ELSE '4. Over 1 year' END
ORDER BY expiry_bucket;

-- Q4. Save it before it expires: near-expiry stock that another branch in the same region
--     sells fast enough to clear before the expiry date
WITH near AS (
    SELECT b.location_key, b.product_key, b.batch_no, b.qty_on_hand, b.stock_value, b.days_to_expiry
    FROM dw.fact_inventory_batch b
    JOIN dw.dim_location l ON l.location_key = b.location_key
    WHERE b.days_to_expiry BETWEEN 1 AND 120 AND l.location_type = 'Branch'
),
velocity AS (   -- units per day in Q4 2025 per branch and product
    SELECT f.location_key, f.product_key, SUM(f.qty) / 92.0 AS units_per_day
    FROM dw.fact_sales f
    WHERE f.date_key BETWEEN 20251001 AND 20251231
    GROUP BY f.location_key, f.product_key
),
best AS (
    SELECT n.batch_no, n.location_key AS from_key, v.location_key AS to_key, v.units_per_day,
           ROW_NUMBER() OVER (PARTITION BY n.location_key, n.batch_no ORDER BY v.units_per_day DESC) AS rn
    FROM near n
    JOIN dw.dim_location lf ON lf.location_key = n.location_key
    JOIN velocity v         ON v.product_key = n.product_key AND v.location_key <> n.location_key
    JOIN dw.dim_location lt ON lt.location_key = v.location_key AND lt.region = lf.region
)
SELECT TOP 20 lf.location_code AS from_branch, p.product_name, n.batch_no, n.days_to_expiry, n.qty_on_hand,
       CAST(n.stock_value AS DECIMAL(10,0))                                  AS value_sar,
       lt.location_code                                                      AS transfer_to,
       CAST(bt.units_per_day AS DECIMAL(6,2))                                AS target_units_per_day,
       CAST(n.qty_on_hand / NULLIF(bt.units_per_day, 0) AS DECIMAL(8,0))     AS days_to_sell_there,
       CASE WHEN n.qty_on_hand / NULLIF(bt.units_per_day, 0) < n.days_to_expiry - 14
            THEN 'Transfer' ELSE 'Mark down' END                             AS recommended_action
FROM near n
JOIN best bt            ON bt.batch_no = n.batch_no AND bt.from_key = n.location_key AND bt.rn = 1
JOIN dw.dim_location lf ON lf.location_key = n.location_key
JOIN dw.dim_location lt ON lt.location_key = bt.to_key
JOIN dw.dim_product p   ON p.product_key = n.product_key
ORDER BY n.stock_value DESC;

-- Q5. Write-offs: expired and damaged stock by reason and department, vs. cost of goods sold
WITH wo AS (
    SELECT d.[year], w.reason, p.department, SUM(w.qty) AS units, SUM(w.cost_value) AS cost_value
    FROM dw.fact_writeoff w
    JOIN dw.dim_product p ON p.product_key = w.product_key
    JOIN dw.dim_date d    ON d.date_key = w.date_key
    GROUP BY d.[year], w.reason, p.department
),
cogs AS (
    SELECT d.[year], SUM(f.cost_amount) AS cogs
    FROM dw.fact_sales f JOIN dw.dim_date d ON d.date_key = f.date_key
    GROUP BY d.[year]
)
SELECT wo.[year], wo.reason, wo.department, wo.units,
       CAST(wo.cost_value AS DECIMAL(12,0))                       AS cost_value_sar,
       CAST(100.0 * wo.cost_value / c.cogs AS DECIMAL(6,3))       AS pct_of_cogs
FROM wo
JOIN cogs c ON c.[year] = wo.[year]
ORDER BY wo.[year], cost_value_sar DESC;

-- Q6. What stock-outs cost: estimated lost sales = normal daily sales x days out of stock
WITH normal_rate AS (   -- average daily net sales per branch and product on days it was available
    SELECT f.location_key, f.product_key,
           SUM(f.net_amount) / 731.0 AS sales_per_day,
           SUM(f.net_amount - f.cost_amount) / 731.0 AS profit_per_day
    FROM dw.fact_sales f
    GROUP BY f.location_key, f.product_key
)
SELECT e.reason, p.department,
       COUNT(*)                                                      AS events,
       SUM(e.days_out)                                               AS branch_days_out,
       CAST(SUM(e.days_out * COALESCE(r.sales_per_day, 0)) / 1e3 AS DECIMAL(10,1))  AS est_lost_sales_k_sar,
       CAST(SUM(e.days_out * COALESCE(r.profit_per_day, 0)) / 1e3 AS DECIMAL(10,1)) AS est_lost_profit_k_sar
FROM dw.fact_stockout_event e
JOIN dw.dim_product p   ON p.product_key = e.product_key
LEFT JOIN normal_rate r ON r.location_key = e.location_key AND r.product_key = e.product_key
GROUP BY e.reason, p.department
ORDER BY est_lost_sales_k_sar DESC;

-- Q7. National shortages (GLP-1 injectables 2024, amoxicillin suspension, oseltamivir):
--     how long were branches without stock, and the monthly units sold around the shortage
SELECT p.scientific_name,
       MIN(ds.full_date)                                     AS first_branch_out,
       MAX(de.full_date)                                     AS back_in_stock,
       COUNT(DISTINCT e.location_key)                        AS branches_affected,
       CAST(AVG(1.0 * e.days_out) AS DECIMAL(6,1))           AS avg_days_out_per_branch
FROM dw.fact_stockout_event e
JOIN dw.dim_product p ON p.product_key = e.product_key
JOIN dw.dim_date ds   ON ds.date_key = e.start_date_key
JOIN dw.dim_date de   ON de.date_key = e.end_date_key
WHERE e.reason = 'National shortage'
GROUP BY p.scientific_name
ORDER BY first_branch_out;

-- Q8. Overstock: branch-items holding more than 120 days of stock at year-end (cash tied up)
WITH v AS (
    SELECT f.location_key, f.product_key, SUM(f.qty) / 92.0 AS units_per_day
    FROM dw.fact_sales f
    WHERE f.date_key BETWEEN 20251001 AND 20251231
    GROUP BY f.location_key, f.product_key
)
SELECT TOP 20 l.location_code, p.product_name, p.department,
       i.qty_on_hand,
       CAST(v.units_per_day AS DECIMAL(6,2))                                AS units_per_day,
       CAST(i.qty_on_hand / NULLIF(v.units_per_day, 0) AS DECIMAL(8,0))     AS days_of_cover,
       CAST(i.stock_value AS DECIMAL(10,0))                                 AS stock_value_sar
FROM dw.fact_inventory_month_end i
JOIN dw.dim_location l ON l.location_key = i.location_key AND l.location_type = 'Branch'
JOIN dw.dim_product p  ON p.product_key = i.product_key
LEFT JOIN v            ON v.location_key = i.location_key AND v.product_key = i.product_key
WHERE i.snapshot_date_key = 20251231
  AND (v.units_per_day IS NULL OR i.qty_on_hand / v.units_per_day > 120)
ORDER BY i.stock_value DESC;
