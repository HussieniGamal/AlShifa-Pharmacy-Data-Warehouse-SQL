/* =============================================================================
   06  Sales department analysis
   -----------------------------------------------------------------------------
   Business owner : Sales Director / Area Managers
   Questions      : How are we growing, where, when do customers buy, and which
                    branches need attention?
   ============================================================================= */
USE AlShifaDW;
GO

-- Q1. Executive KPIs by year
SELECT d.[year],
       COUNT(DISTINCT f.location_key)                                             AS trading_branches,
       CAST(SUM(f.net_amount) / 1e6 AS DECIMAL(10,2))                             AS net_sales_m_sar,
       CAST(100.0 * SUM(f.net_amount - f.cost_amount) / SUM(f.net_amount) AS DECIMAL(5,1)) AS gross_margin_pct,
       COUNT(DISTINCT CASE WHEN f.line_type = 'Sale' THEN f.invoice_no END)       AS invoices,
       CAST(SUM(CASE WHEN f.line_type = 'Sale' THEN f.net_amount END)
            / COUNT(DISTINCT CASE WHEN f.line_type = 'Sale' THEN f.invoice_no END) AS DECIMAL(10,2)) AS avg_basket_sar,
       CAST(1.0 * SUM(CASE WHEN f.line_type = 'Sale' THEN f.qty END)
            / COUNT(DISTINCT CASE WHEN f.line_type = 'Sale' THEN f.invoice_no END) AS DECIMAL(5,2)) AS units_per_basket,
       CAST(100.0 * -SUM(CASE WHEN f.line_type = 'Return' THEN f.net_amount ELSE 0 END)
            / SUM(CASE WHEN f.line_type = 'Sale' THEN f.net_amount END) AS DECIMAL(5,2)) AS returns_pct
FROM dw.fact_sales f
JOIN dw.dim_date d ON d.date_key = f.date_key
GROUP BY d.[year]
ORDER BY d.[year];

-- Q2. Monthly net sales with month-over-month and year-over-year growth
WITH m AS (
    SELECT d.year_month, d.[year], d.[month], SUM(f.net_amount) AS net_sales
    FROM dw.fact_sales f
    JOIN dw.dim_date d ON d.date_key = f.date_key
    GROUP BY d.year_month, d.[year], d.[month]
)
SELECT year_month,
       CAST(net_sales / 1e3 AS DECIMAL(12,1)) AS net_sales_k_sar,
       CAST(100.0 * (net_sales - LAG(net_sales, 1) OVER (ORDER BY year_month))
            / LAG(net_sales, 1) OVER (ORDER BY year_month) AS DECIMAL(6,1))  AS mom_pct,
       CAST(100.0 * (net_sales - LAG(net_sales, 12) OVER (ORDER BY year_month))
            / LAG(net_sales, 12) OVER (ORDER BY year_month) AS DECIMAL(6,1)) AS yoy_pct
FROM m
ORDER BY year_month;

-- Q3. Like-for-like growth: total growth vs. growth from branches that traded all of 2024 and 2025
WITH by_branch AS (
    SELECT f.location_key,
           SUM(CASE WHEN d.[year] = 2024 THEN f.net_amount ELSE 0 END) AS sales_2024,
           SUM(CASE WHEN d.[year] = 2025 THEN f.net_amount ELSE 0 END) AS sales_2025
    FROM dw.fact_sales f
    JOIN dw.dim_date d ON d.date_key = f.date_key
    GROUP BY f.location_key
)
SELECT CASE WHEN l.open_date < '2024-01-01' THEN 'Like-for-like (35 - 3 new)' ELSE 'New branches 2025' END AS branch_group,
       COUNT(*)                                            AS branches,
       CAST(SUM(sales_2024) / 1e6 AS DECIMAL(10,2))        AS sales_2024_m,
       CAST(SUM(sales_2025) / 1e6 AS DECIMAL(10,2))        AS sales_2025_m,
       CAST(100.0 * (SUM(sales_2025) - SUM(sales_2024)) / NULLIF(SUM(sales_2024), 0) AS DECIMAL(6,1)) AS growth_pct
FROM by_branch b
JOIN dw.dim_location l ON l.location_key = b.location_key
GROUP BY CASE WHEN l.open_date < '2024-01-01' THEN 'Like-for-like (35 - 3 new)' ELSE 'New branches 2025' END;

-- Q4. Branch league table 2025: sales density, rank inside the region, gap to the regional median
WITH b AS (
    SELECT l.location_code, l.city, l.region, l.branch_type, l.size_sqm,
           SUM(f.net_amount)                                    AS net_sales,
           SUM(f.net_amount) / COUNT(DISTINCT f.date_key)       AS sales_per_day,
           SUM(f.net_amount) / l.size_sqm                       AS sales_per_sqm,
           100.0 * SUM(f.net_amount - f.cost_amount) / SUM(f.net_amount) AS margin_pct
    FROM dw.fact_sales f
    JOIN dw.dim_location l ON l.location_key = f.location_key
    JOIN dw.dim_date d     ON d.date_key = f.date_key
    WHERE d.[year] = 2025
    GROUP BY l.location_code, l.city, l.region, l.branch_type, l.size_sqm
)
SELECT location_code, city, region, branch_type,
       CAST(net_sales / 1e3 AS DECIMAL(12,0))     AS net_sales_k_sar,
       CAST(sales_per_day AS DECIMAL(10,0))       AS sales_per_trading_day,
       CAST(sales_per_sqm AS DECIMAL(10,0))       AS sales_per_sqm,
       CAST(margin_pct AS DECIMAL(5,1))           AS margin_pct,
       RANK() OVER (PARTITION BY region ORDER BY sales_per_day DESC) AS rank_in_region,
       NTILE(4) OVER (ORDER BY sales_per_day DESC)                   AS chain_quartile
FROM b
ORDER BY sales_per_day DESC;

-- Q5. When do customers buy? Average invoices per hour: normal days vs. Ramadan vs. Friday
WITH h AS (
    SELECT CASE WHEN d.is_ramadan = 1 THEN 'Ramadan'
                WHEN d.day_name = 'Friday' THEN 'Friday'
                ELSE 'Normal day' END                  AS day_type,
           f.hour_of_day,
           COUNT(DISTINCT f.invoice_no)                AS invoices,
           COUNT(DISTINCT f.date_key)                  AS days
    FROM dw.fact_sales f
    JOIN dw.dim_date d ON d.date_key = f.date_key
    WHERE f.line_type = 'Sale'
    GROUP BY CASE WHEN d.is_ramadan = 1 THEN 'Ramadan'
                  WHEN d.day_name = 'Friday' THEN 'Friday'
                  ELSE 'Normal day' END, f.hour_of_day
)
SELECT hour_of_day,
       CAST(SUM(CASE WHEN day_type = 'Normal day' THEN 1.0 * invoices / days END) AS DECIMAL(8,1)) AS normal_day,
       CAST(SUM(CASE WHEN day_type = 'Friday'     THEN 1.0 * invoices / days END) AS DECIMAL(8,1)) AS friday,
       CAST(SUM(CASE WHEN day_type = 'Ramadan'    THEN 1.0 * invoices / days END) AS DECIMAL(8,1)) AS ramadan
FROM h
GROUP BY hour_of_day
ORDER BY hour_of_day;

-- Q6. Ramadan and Eid effect by department: average daily sales vs. the rest of the year
WITH daily AS (
    SELECT d.full_date, d.is_ramadan, d.is_eid, p.department, SUM(f.net_amount) AS sales
    FROM dw.fact_sales f
    JOIN dw.dim_date d    ON d.date_key = f.date_key
    JOIN dw.dim_product p ON p.product_key = f.product_key
    JOIN dw.dim_location l ON l.location_key = f.location_key
    WHERE l.open_date < '2024-01-01'
    GROUP BY d.full_date, d.is_ramadan, d.is_eid, p.department
)
SELECT department,
       CAST(AVG(CASE WHEN is_ramadan = 0 AND is_eid = 0 THEN sales END) AS DECIMAL(12,0)) AS normal_day_sar,
       CAST(AVG(CASE WHEN is_ramadan = 1 THEN sales END) AS DECIMAL(12,0))                AS ramadan_day_sar,
       CAST(AVG(CASE WHEN is_eid = 1 THEN sales END) AS DECIMAL(12,0))                    AS eid_day_sar,
       CAST(100.0 * AVG(CASE WHEN is_ramadan = 1 THEN sales END)
            / AVG(CASE WHEN is_ramadan = 0 AND is_eid = 0 THEN sales END) - 100 AS DECIMAL(6,1)) AS ramadan_vs_normal_pct
FROM daily
GROUP BY department
ORDER BY ramadan_vs_normal_pct DESC;

-- Q7. Payment mix by branch type (insurance share drives cash-collection risk)
SELECT l.branch_type,
       CAST(100.0 * SUM(CASE WHEN f.payment_type = 'Insurance' THEN f.net_amount END) / SUM(f.net_amount) AS DECIMAL(5,1)) AS insurance_pct,
       CAST(100.0 * SUM(CASE WHEN f.payment_type = 'Card'      THEN f.net_amount END) / SUM(f.net_amount) AS DECIMAL(5,1)) AS card_pct,
       CAST(100.0 * SUM(CASE WHEN f.payment_type = 'Cash'      THEN f.net_amount END) / SUM(f.net_amount) AS DECIMAL(5,1)) AS cash_pct,
       CAST(100.0 * SUM(CASE WHEN f.payment_type = 'BNPL'      THEN f.net_amount END) / SUM(f.net_amount) AS DECIMAL(5,1)) AS bnpl_pct
FROM dw.fact_sales f
JOIN dw.dim_location l ON l.location_key = f.location_key
WHERE f.line_type = 'Sale'
GROUP BY l.branch_type
ORDER BY insurance_pct DESC;

-- Q8. Loyalty members vs. walk-in customers
WITH inv AS (
    SELECT f.invoice_no,
           MAX(CASE WHEN f.customer_key = -1 THEN 'Walk-in' ELSE 'Loyalty member' END) AS customer_type,
           SUM(f.net_amount) AS basket_value,
           SUM(f.qty)        AS units
    FROM dw.fact_sales f
    WHERE f.line_type = 'Sale'
    GROUP BY f.invoice_no
)
SELECT customer_type,
       COUNT(*)                                                    AS invoices,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct_of_invoices,
       CAST(100.0 * SUM(basket_value) / SUM(SUM(basket_value)) OVER () AS DECIMAL(5,1)) AS pct_of_sales,
       CAST(AVG(basket_value) AS DECIMAL(10,2))                    AS avg_basket_sar,
       CAST(AVG(1.0 * units) AS DECIMAL(5,2))                      AS avg_units
FROM inv
GROUP BY customer_type;

-- Q9. New branches: how many weeks until they reach 80% of a mature branch's weekly sales?
WITH wk AS (
    SELECT l.location_code, l.open_date,
           (DATEDIFF(DAY, l.open_date, d.full_date) - DATEDIFF(DAY, l.open_date, d.full_date) % 7) / 7 + 1  AS week_since_open,
           SUM(f.net_amount)                                AS week_sales
    FROM dw.fact_sales f
    JOIN dw.dim_location l ON l.location_key = f.location_key
    JOIN dw.dim_date d     ON d.date_key = f.date_key
    WHERE l.open_date >= '2025-01-01'
    GROUP BY l.location_code, l.open_date, (DATEDIFF(DAY, l.open_date, d.full_date) - DATEDIFF(DAY, l.open_date, d.full_date) % 7) / 7 + 1
),
benchmark AS (   -- average weekly sales of mature branches of the same chain in 2025
    SELECT SUM(f.net_amount) / COUNT(DISTINCT f.location_key) / 52.0 AS mature_week_sales
    FROM dw.fact_sales f
    JOIN dw.dim_location l ON l.location_key = f.location_key
    JOIN dw.dim_date d     ON d.date_key = f.date_key
    WHERE d.[year] = 2025 AND l.open_date < '2024-01-01'
)
SELECT w.location_code, w.open_date,
       MAX(w.week_since_open)                                                 AS weeks_trading,
       MIN(CASE WHEN w.week_sales >= 0.8 * b.mature_week_sales THEN w.week_since_open END) AS first_week_at_80pct,
       CAST(100.0 * MAX(CASE WHEN w.week_since_open = 4 THEN w.week_sales END) / MAX(b.mature_week_sales) AS DECIMAL(5,1)) AS week4_vs_mature_pct,
       CAST(100.0 * AVG(CASE WHEN w.week_since_open >= MAXW.maxw - 3 THEN w.week_sales END) / MAX(b.mature_week_sales) AS DECIMAL(5,1)) AS last4wk_vs_mature_pct
FROM wk w
CROSS JOIN benchmark b
JOIN (SELECT location_code, MAX(week_since_open) - 1 AS maxw FROM wk GROUP BY location_code) MAXW
  ON MAXW.location_code = w.location_code
GROUP BY w.location_code, w.open_date
ORDER BY w.open_date;

-- Q10. Staff productivity 2025: invoices and sales per staff member, ranked inside each branch
WITH s AS (
    SELECT l.location_code, e.employee_code, e.job_title,
           COUNT(DISTINCT f.invoice_no) AS invoices,
           SUM(f.net_amount)            AS net_sales,
           SUM(CASE WHEN p.is_rx = 1 THEN f.net_amount ELSE 0 END) AS rx_sales
    FROM dw.fact_sales f
    JOIN dw.dim_employee e ON e.employee_key = f.employee_key
    JOIN dw.dim_location l ON l.location_key = f.location_key
    JOIN dw.dim_product p  ON p.product_key = f.product_key
    JOIN dw.dim_date d     ON d.date_key = f.date_key
    WHERE d.[year] = 2025 AND f.line_type = 'Sale'
    GROUP BY l.location_code, e.employee_code, e.job_title
)
SELECT TOP 15 location_code, employee_code, job_title, invoices,
       CAST(net_sales / 1e3 AS DECIMAL(10,1))                        AS net_sales_k_sar,
       CAST(100.0 * rx_sales / net_sales AS DECIMAL(5,1))            AS rx_share_pct,
       RANK() OVER (PARTITION BY location_code ORDER BY net_sales DESC) AS rank_in_branch
FROM s
ORDER BY net_sales DESC;
