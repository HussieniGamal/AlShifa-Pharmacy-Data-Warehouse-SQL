/* =============================================================================
   08  Purchasing & supplier analysis
   -----------------------------------------------------------------------------
   Business owner : Purchasing Manager
   Questions      : Which suppliers deliver on time and in full, where is the
                    money going, and which supplier problems reach the shelf?
   ============================================================================= */
USE AlShifaDW;
GO

-- Q1. Supplier scorecard (received PO lines only; lines with date errors excluded)
SELECT s.supplier_code, s.supplier_name, s.agreed_lead_days,
       COUNT(DISTINCT f.po_no)                                                AS purchase_orders,
       CAST(SUM(f.received_value) / 1e3 AS DECIMAL(12,0))                     AS received_value_k_sar,
       CAST(AVG(1.0 * f.lead_time_days) AS DECIMAL(5,1))                       AS avg_actual_lead_days,
       CAST(100.0 * AVG(1.0 * f.is_on_time) AS DECIMAL(5,1))                   AS on_time_pct,
       CAST(100.0 * AVG(1.0 * f.is_in_full) AS DECIMAL(5,1))                   AS in_full_pct,
       CAST(100.0 * AVG(CASE WHEN f.is_on_time = 1 AND f.is_in_full = 1 THEN 1.0 ELSE 0 END) AS DECIMAL(5,1)) AS otif_pct,
       CAST(100.0 * SUM(f.qty_received) / SUM(f.qty_ordered) AS DECIMAL(5,1))  AS unit_fill_rate_pct,
       RANK() OVER (ORDER BY AVG(CASE WHEN f.is_on_time = 1 AND f.is_in_full = 1 THEN 1.0 ELSE 0 END) DESC) AS otif_rank
FROM dw.fact_purchase_order_line f
JOIN dw.dim_supplier s ON s.supplier_key = f.supplier_key
WHERE f.received_date_key IS NOT NULL AND f.dq_issue IS NULL
GROUP BY s.supplier_code, s.supplier_name, s.agreed_lead_days
ORDER BY otif_pct DESC;

-- Q2. Spend concentration: share of purchase value per supplier and the cumulative share
WITH sp AS (
    SELECT s.supplier_name, SUM(f.order_value) AS spend
    FROM dw.fact_purchase_order_line f
    JOIN dw.dim_supplier s ON s.supplier_key = f.supplier_key
    JOIN dw.dim_date d     ON d.date_key = f.order_date_key
    WHERE d.[year] = 2025
    GROUP BY s.supplier_name
)
SELECT supplier_name,
       CAST(spend / 1e3 AS DECIMAL(12,0))                                                            AS spend_k_sar,
       CAST(100.0 * spend / SUM(spend) OVER () AS DECIMAL(5,1))                                       AS share_pct,
       CAST(100.0 * SUM(spend) OVER (ORDER BY spend DESC ROWS UNBOUNDED PRECEDING) / SUM(spend) OVER () AS DECIMAL(5,1)) AS cumulative_pct
FROM sp
ORDER BY spend DESC;

-- Q3. Delay distribution per supplier: how late are the late deliveries?
SELECT s.supplier_name,
       SUM(CASE WHEN f.delay_days <= 0 THEN 1 ELSE 0 END)              AS on_time_or_early,
       SUM(CASE WHEN f.delay_days BETWEEN 1 AND 2 THEN 1 ELSE 0 END)   AS late_1_2_days,
       SUM(CASE WHEN f.delay_days BETWEEN 3 AND 6 THEN 1 ELSE 0 END)   AS late_3_6_days,
       SUM(CASE WHEN f.delay_days >= 7 THEN 1 ELSE 0 END)              AS late_7_plus_days,
       MAX(f.delay_days)                                               AS worst_delay_days
FROM (SELECT DISTINCT po_no, supplier_key, delay_days FROM dw.fact_purchase_order_line
      WHERE received_date_key IS NOT NULL AND dq_issue IS NULL) f
JOIN dw.dim_supplier s ON s.supplier_key = f.supplier_key
GROUP BY s.supplier_name
ORDER BY late_7_plus_days DESC;

-- Q4. Purchase price inflation: weighted average unit cost 2025 vs. 2024, by supplier
WITH like_for_like AS (   -- same product, same supplier, so the product mix cannot fake inflation
    SELECT s.supplier_name, f.product_key,
           SUM(CASE WHEN d.[year] = 2024 THEN f.order_value END) / NULLIF(SUM(CASE WHEN d.[year] = 2024 THEN f.qty_ordered END), 0) AS cost_2024,
           SUM(CASE WHEN d.[year] = 2025 THEN f.order_value END) / NULLIF(SUM(CASE WHEN d.[year] = 2025 THEN f.qty_ordered END), 0) AS cost_2025,
           SUM(CASE WHEN d.[year] = 2025 THEN f.order_value END) AS spend_2025
    FROM dw.fact_purchase_order_line f
    JOIN dw.dim_supplier s ON s.supplier_key = f.supplier_key
    JOIN dw.dim_date d     ON d.date_key = f.order_date_key
    GROUP BY s.supplier_name, f.product_key
)
SELECT supplier_name,
       COUNT(*)                                                                         AS products_bought_both_years,
       CAST(100.0 * SUM(spend_2025 * (cost_2025 / cost_2024 - 1)) / SUM(spend_2025) AS DECIMAL(5,2)) AS weighted_cost_inflation_pct
FROM like_for_like
WHERE cost_2024 IS NOT NULL AND cost_2025 IS NOT NULL
GROUP BY supplier_name
ORDER BY weighted_cost_inflation_pct DESC;

-- Q5. Does a weak supplier reach the shelf? Stock-out days per 100 listed items, by supplier
WITH items AS (
    SELECT supplier_key, COUNT(*) AS listed_items FROM dw.dim_product GROUP BY supplier_key
),
so AS (
    SELECT p.supplier_key,
           COUNT(*)            AS stockout_events,
           SUM(e.days_out)     AS stockout_days
    FROM dw.fact_stockout_event e
    JOIN dw.dim_product p ON p.product_key = e.product_key
    WHERE e.reason <> 'National shortage'
    GROUP BY p.supplier_key
)
SELECT s.supplier_name, i.listed_items, so.stockout_events, so.stockout_days,
       CAST(100.0 * so.stockout_days / i.listed_items / 35 AS DECIMAL(8,1)) AS stockout_days_per_100_items_per_branch
FROM so
JOIN items i           ON i.supplier_key = so.supplier_key
JOIN dw.dim_supplier s ON s.supplier_key = so.supplier_key
ORDER BY stockout_days_per_100_items_per_branch DESC;

-- Q6. Overdue open purchase orders at year-end (expected date passed, nothing received)
SELECT TOP 15 f.po_no, s.supplier_name, l.location_code AS warehouse,
       de.full_date                                   AS expected_date,
       DATEDIFF(DAY, de.full_date, CAST('2025-12-31' AS DATE)) AS days_overdue,
       COUNT(*)                                       AS lines,
       CAST(SUM(f.order_value) AS DECIMAL(12,0))      AS open_value_sar
FROM dw.fact_purchase_order_line f
JOIN dw.dim_supplier s ON s.supplier_key = f.supplier_key
JOIN dw.dim_location l ON l.location_key = f.location_key
JOIN dw.dim_date de    ON de.date_key = f.expected_date_key
WHERE f.po_status = 'Open' AND de.full_date < '2025-12-31'
GROUP BY f.po_no, s.supplier_name, l.location_code, de.full_date
ORDER BY days_overdue DESC, open_value_sar DESC;

-- Q7. Buying vs. selling: units received vs. units sold by department in 2025 (over/under buying)
WITH bought AS (
    SELECT p.department, SUM(f.qty_received) AS units_received
    FROM dw.fact_purchase_order_line f
    JOIN dw.dim_product p ON p.product_key = f.product_key
    JOIN dw.dim_date d    ON d.date_key = f.order_date_key
    WHERE d.[year] = 2025
    GROUP BY p.department
),
sold AS (
    SELECT p.department, SUM(f.qty) AS units_sold
    FROM dw.fact_sales f
    JOIN dw.dim_product p ON p.product_key = f.product_key
    JOIN dw.dim_date d    ON d.date_key = f.date_key
    WHERE d.[year] = 2025
    GROUP BY p.department
)
SELECT b.department, b.units_received, s.units_sold,
       CAST(100.0 * b.units_received / s.units_sold AS DECIMAL(6,1)) AS received_to_sold_pct
FROM bought b
JOIN sold s ON s.department = b.department
ORDER BY received_to_sold_pct DESC;
