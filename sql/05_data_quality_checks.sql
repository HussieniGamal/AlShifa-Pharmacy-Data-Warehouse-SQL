/* =============================================================================
   05  Data quality checks
   -----------------------------------------------------------------------------
   Run after every load. Each query returns one row per check with the number
   of offending rows, so it can feed a data-quality dashboard or an alert.
   ============================================================================= */
USE AlShifaDW;
GO

-- Q1. Source-level problems found in staging (what the cleaning rules had to fix)
SELECT 'POS: duplicated lines (same invoice + product uploaded twice)' AS check_name,
       COUNT(*) - COUNT(DISTINCT CONCAT(TRIM(invoice_no), '|', UPPER(TRIM(product_code)))) AS issue_rows
FROM stg.pos_sales_lines
UNION ALL
SELECT 'POS: product codes with spaces or lower case',
       SUM(CASE WHEN product_code <> UPPER(TRIM(product_code)) THEN 1 ELSE 0 END)
FROM stg.pos_sales_lines
UNION ALL
SELECT 'POS: return lines (negative quantity)',
       SUM(CASE WHEN TRY_CAST(qty AS INT) < 0 THEN 1 ELSE 0 END)
FROM stg.pos_sales_lines
UNION ALL
SELECT 'POS: unparseable timestamp or quantity',
       SUM(CASE WHEN TRY_CAST(invoice_ts AS DATETIME2) IS NULL OR TRY_CAST(qty AS INT) IS NULL THEN 1 ELSE 0 END)
FROM stg.pos_sales_lines
UNION ALL
SELECT 'ERP: PO lines received before they were ordered',
       SUM(CASE WHEN TRY_CAST(received_date AS DATE) < TRY_CAST(order_date AS DATE) THEN 1 ELSE 0 END)
FROM stg.erp_purchase_orders
UNION ALL
SELECT 'CRM: customers without a valid home branch',
       SUM(CASE WHEN home_branch_code IS NULL OR home_branch_code NOT IN (SELECT branch_code FROM stg.erp_branches) THEN 1 ELSE 0 END)
FROM stg.crm_customers;

-- Q2. Reconciliation: staging lines vs. loaded fact lines (difference must equal the duplicates)
SELECT (SELECT COUNT(*) FROM stg.pos_sales_lines)          AS staging_lines,
       (SELECT COUNT(*) FROM dw.fact_sales)                 AS fact_lines,
       (SELECT COUNT(*) FROM stg.pos_sales_lines) - (SELECT COUNT(*) FROM dw.fact_sales) AS lines_not_loaded;

-- Q3. Orphans: fact rows pointing to an unknown member
SELECT 'Sales lines without a loyalty customer (walk-in)' AS check_name,
       COUNT(*) AS row_count,
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dw.fact_sales) AS DECIMAL(5,1)) AS pct_of_lines
FROM dw.fact_sales WHERE customer_key = -1
UNION ALL
SELECT 'Sales lines without a known cashier', COUNT(*),
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dw.fact_sales) AS DECIMAL(5,1))
FROM dw.fact_sales WHERE employee_key = -1;

-- Q4. Business-rule checks on the cleaned data
SELECT 'Sales sold below cost (negative margin lines)' AS check_name,
       COUNT(*) AS row_count
FROM dw.fact_sales WHERE line_type = 'Sale' AND net_amount < cost_amount
UNION ALL
SELECT 'Sales on a date before the branch opened', COUNT(*)
FROM dw.fact_sales f
JOIN dw.dim_location l ON l.location_key = f.location_key
JOIN dw.dim_date d     ON d.date_key = f.date_key
WHERE d.full_date < l.open_date
UNION ALL
SELECT 'Batches already expired but still on hand', COUNT(*)
FROM dw.fact_inventory_batch WHERE days_to_expiry < 0
UNION ALL
SELECT 'PO lines flagged with a date problem', COUNT(*)
FROM dw.fact_purchase_order_line WHERE dq_issue IS NOT NULL;

-- Q5. Freshness: first and last sales date per branch (gaps = missing POS files)
SELECT TOP 10 l.location_code, l.open_date,
       MIN(d.full_date) AS first_sale, MAX(d.full_date) AS last_sale,
       COUNT(DISTINCT f.date_key) AS trading_days
FROM dw.fact_sales f
JOIN dw.dim_location l ON l.location_key = f.location_key
JOIN dw.dim_date d     ON d.date_key = f.date_key
GROUP BY l.location_code, l.open_date
ORDER BY trading_days;
