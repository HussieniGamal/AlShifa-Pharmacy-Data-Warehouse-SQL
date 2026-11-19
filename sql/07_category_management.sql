/* =============================================================================
   07  Category management analysis
   -----------------------------------------------------------------------------
   Business owner : Category Management
   Questions      : Which categories make the money, which items deserve shelf
                    space, did promotions and the price increase pay off?
   ============================================================================= */
USE AlShifaDW;
GO

-- Q1. Department scorecard 2025: sales, margin and share of the chain
SELECT p.department,
       CAST(SUM(f.net_amount) / 1e3 AS DECIMAL(12,0))                                    AS net_sales_k_sar,
       CAST(100.0 * SUM(f.net_amount) / SUM(SUM(f.net_amount)) OVER () AS DECIMAL(5,1))   AS sales_share_pct,
       CAST(SUM(f.net_amount - f.cost_amount) / 1e3 AS DECIMAL(12,0))                    AS gross_profit_k_sar,
       CAST(100.0 * SUM(f.net_amount - f.cost_amount) / SUM(SUM(f.net_amount - f.cost_amount)) OVER () AS DECIMAL(5,1)) AS profit_share_pct,
       CAST(100.0 * SUM(f.net_amount - f.cost_amount) / SUM(f.net_amount) AS DECIMAL(5,1)) AS margin_pct
FROM dw.fact_sales f
JOIN dw.dim_product p ON p.product_key = f.product_key
JOIN dw.dim_date d    ON d.date_key = f.date_key
WHERE d.[year] = 2025
GROUP BY p.department
ORDER BY gross_profit_k_sar DESC;

-- Q2. ABC classification of the range by 2025 revenue (A = first 80%, B = next 15%, C = last 5%)
WITH r AS (
    SELECT p.product_key, p.department, SUM(f.net_amount) AS revenue
    FROM dw.fact_sales f
    JOIN dw.dim_product p ON p.product_key = f.product_key
    JOIN dw.dim_date d    ON d.date_key = f.date_key
    WHERE d.[year] = 2025
    GROUP BY p.product_key, p.department
),
c AS (
    SELECT *, SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING) / SUM(revenue) OVER () AS cum_share
    FROM r
)
SELECT CASE WHEN cum_share <= 0.80 THEN 'A' WHEN cum_share <= 0.95 THEN 'B' ELSE 'C' END AS abc_class,
       COUNT(*)                                                         AS products,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))   AS pct_of_range,
       CAST(SUM(revenue) / 1e3 AS DECIMAL(12,0))                        AS revenue_k_sar,
       CAST(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER () AS DECIMAL(5,1)) AS pct_of_revenue
FROM c
GROUP BY CASE WHEN cum_share <= 0.80 THEN 'A' WHEN cum_share <= 0.95 THEN 'B' ELSE 'C' END
ORDER BY abc_class;

-- Q3. Top 3 products in every category (2025 revenue)
WITH r AS (
    SELECT p.category, p.product_name, p.brand,
           SUM(f.qty)        AS units,
           SUM(f.net_amount) AS revenue,
           ROW_NUMBER() OVER (PARTITION BY p.category ORDER BY SUM(f.net_amount) DESC) AS rn
    FROM dw.fact_sales f
    JOIN dw.dim_product p ON p.product_key = f.product_key
    JOIN dw.dim_date d    ON d.date_key = f.date_key
    WHERE d.[year] = 2025
    GROUP BY p.category, p.product_name, p.brand
)
SELECT category, rn AS rank_in_category, product_name, brand, units,
       CAST(revenue AS DECIMAL(12,0)) AS revenue_sar
FROM r
WHERE rn <= 3
ORDER BY category, rn;

-- Q4. Promotion effectiveness: units per day during the promotion vs. the 28 days before,
--     and whether the extra volume paid for the discount
WITH promo_items AS (       -- items that actually sold on promotion
    SELECT DISTINCT f.promotion_key, f.product_key
    FROM dw.fact_sales f
    WHERE f.promotion_key <> -1
),
daily AS (
    SELECT pr.promotion_key, pr.promo_name, pr.start_date, pr.end_date, pr.discount_pct,
           CASE WHEN d.full_date BETWEEN pr.start_date AND pr.end_date THEN 'During' ELSE 'Before' END AS period,
           SUM(f.qty)                         AS units,
           SUM(f.net_amount - f.cost_amount)  AS gross_profit
    FROM dw.dim_promotion pr
    JOIN promo_items pi   ON pi.promotion_key = pr.promotion_key
    JOIN dw.fact_sales f  ON f.product_key = pi.product_key
    JOIN dw.dim_date d    ON d.date_key = f.date_key
    WHERE d.full_date BETWEEN DATEADD(DAY, -28, pr.start_date) AND pr.end_date
      AND f.line_type = 'Sale'
    GROUP BY pr.promotion_key, pr.promo_name, pr.start_date, pr.end_date, pr.discount_pct,
             CASE WHEN d.full_date BETWEEN pr.start_date AND pr.end_date THEN 'During' ELSE 'Before' END
)
SELECT promo_name, start_date, CAST(100 * discount_pct AS INT) AS discount_pct,
       CAST(MAX(CASE WHEN period = 'Before' THEN units END) / 28.0 AS DECIMAL(10,1))  AS units_per_day_before,
       CAST(MAX(CASE WHEN period = 'During' THEN units END) * 1.0
            / (DATEDIFF(DAY, start_date, end_date) + 1) AS DECIMAL(10,1))            AS units_per_day_during,
       CAST(100.0 * (MAX(CASE WHEN period = 'During' THEN units END) * 1.0 / (DATEDIFF(DAY, start_date, end_date) + 1))
            / (MAX(CASE WHEN period = 'Before' THEN units END) / 28.0) - 100 AS DECIMAL(6,1)) AS volume_uplift_pct,
       CAST(100.0 * (MAX(CASE WHEN period = 'During' THEN gross_profit END) / (DATEDIFF(DAY, start_date, end_date) + 1))
            / (MAX(CASE WHEN period = 'Before' THEN gross_profit END) / 28.0) - 100 AS DECIMAL(6,1)) AS profit_per_day_change_pct
FROM daily
GROUP BY promotion_key, promo_name, start_date, end_date, discount_pct
ORDER BY start_date;

-- Q5. Did the +5% retail price increase on 1 Feb 2025 cost us volume?
--     Difference-in-differences: Feb-Apr 2025 vs. Feb-Apr 2024 (same Ramadan season both years).
--     Regulated medicines kept their SFDA price, so they show the "normal" growth of the chain.
WITH w AS (
    SELECT CASE WHEN p.data_source = 'SFDA drugs list' THEN 'Control: regulated medicines'
                ELSE 'Treated: retail items (+5%)' END AS item_group,
           d.[year],
           SUM(f.qty)        AS units,
           SUM(f.net_amount) AS revenue
    FROM dw.fact_sales f
    JOIN dw.dim_product p  ON p.product_key = f.product_key
    JOIN dw.dim_date d     ON d.date_key = f.date_key
    JOIN dw.dim_location l ON l.location_key = f.location_key
    WHERE d.[month] BETWEEN 2 AND 4 AND l.open_date < '2024-01-01' AND f.line_type = 'Sale'
      AND f.promotion_key = -1                                -- keep promotions out of the comparison
    GROUP BY CASE WHEN p.data_source = 'SFDA drugs list' THEN 'Control: regulated medicines'
                  ELSE 'Treated: retail items (+5%)' END, d.[year]
),
g AS (
    SELECT item_group,
           100.0 * SUM(CASE WHEN [year] = 2025 THEN units END)   / SUM(CASE WHEN [year] = 2024 THEN units END)   - 100 AS unit_growth_pct,
           100.0 * SUM(CASE WHEN [year] = 2025 THEN revenue END) / SUM(CASE WHEN [year] = 2024 THEN revenue END) - 100 AS revenue_growth_pct
    FROM w
    GROUP BY item_group
)
SELECT item_group,
       CAST(unit_growth_pct AS DECIMAL(6,1))    AS unit_growth_yoy_pct,
       CAST(revenue_growth_pct AS DECIMAL(6,1)) AS revenue_growth_yoy_pct,
       CAST(unit_growth_pct - MAX(CASE WHEN item_group LIKE 'Control%' THEN unit_growth_pct END) OVER ()
            AS DECIMAL(6,1))                    AS unit_growth_vs_control_pts
FROM g
ORDER BY item_group DESC;

-- Q6. Private label vs. national brands in the categories where both are sold
WITH cat AS (
    SELECT DISTINCT category FROM dw.dim_product WHERE is_private_label = 1
)
SELECT p.category,
       CASE WHEN p.is_private_label = 1 THEN 'Al Shifa private label' ELSE 'Other brands' END AS label,
       COUNT(DISTINCT p.product_key)                                                         AS items,
       CAST(SUM(f.net_amount) AS DECIMAL(12,0))                                              AS revenue_sar,
       CAST(100.0 * SUM(f.net_amount - f.cost_amount) / SUM(f.net_amount) AS DECIMAL(5,1))   AS margin_pct,
       CAST(SUM(f.net_amount) / COUNT(DISTINCT p.product_key) AS DECIMAL(12,0))              AS revenue_per_item
FROM dw.fact_sales f
JOIN dw.dim_product p ON p.product_key = f.product_key
JOIN cat c            ON c.category = p.category
JOIN dw.dim_date d    ON d.date_key = f.date_key
WHERE d.[year] = 2025
GROUP BY p.category, CASE WHEN p.is_private_label = 1 THEN 'Al Shifa private label' ELSE 'Other brands' END
ORDER BY p.category, label;

-- Q7. Seasonality index by category (month average = 100), the categories that swing most
WITH m AS (
    SELECT p.category, d.[month], SUM(f.qty) AS units
    FROM dw.fact_sales f
    JOIN dw.dim_product p  ON p.product_key = f.product_key
    JOIN dw.dim_date d     ON d.date_key = f.date_key
    JOIN dw.dim_location l ON l.location_key = f.location_key
    WHERE l.open_date < '2024-01-01'
    GROUP BY p.category, d.[month]
),
idx AS (
    SELECT category, [month], 100.0 * units / AVG(units) OVER (PARTITION BY category) AS season_index
    FROM m
)
SELECT TOP 12 category,
       CAST(MAX(season_index) - MIN(season_index) AS DECIMAL(6,0))                AS swing_points,
       CAST(MAX(CASE WHEN [month] = 1  THEN season_index END) AS DECIMAL(5,0))   AS idx_jan,
       CAST(MAX(CASE WHEN [month] = 4  THEN season_index END) AS DECIMAL(5,0))   AS idx_apr,
       CAST(MAX(CASE WHEN [month] = 7  THEN season_index END) AS DECIMAL(5,0))   AS idx_jul,
       CAST(MAX(CASE WHEN [month] = 10 THEN season_index END) AS DECIMAL(5,0))   AS idx_oct,
       CAST(MAX(CASE WHEN [month] = 12 THEN season_index END) AS DECIMAL(5,0))   AS idx_dec
FROM idx
GROUP BY category
ORDER BY swing_points DESC;

-- Q8. Cross-selling: department pairs bought in the same basket, with lift
--     (lift > 1 = bought together more often than chance)
WITH basket AS (
    SELECT DISTINCT f.invoice_no, p.department
    FROM dw.fact_sales f
    JOIN dw.dim_product p ON p.product_key = f.product_key
    WHERE f.line_type = 'Sale'
),
n AS (SELECT COUNT(DISTINCT invoice_no) AS baskets FROM basket),
single AS (SELECT department, COUNT(*) AS cnt FROM basket GROUP BY department),
pairs AS (
    SELECT a.department AS dept_a, b.department AS dept_b, COUNT(*) AS together
    FROM basket a
    JOIN basket b ON b.invoice_no = a.invoice_no AND a.department < b.department
    GROUP BY a.department, b.department
)
SELECT TOP 10 pr.dept_a, pr.dept_b, pr.together AS baskets_together,
       CAST(100.0 * pr.together / n.baskets AS DECIMAL(5,2))                               AS support_pct,
       CAST(1.0 * pr.together * n.baskets / (sa.cnt * sb.cnt) AS DECIMAL(5,2))             AS lift
FROM pairs pr
CROSS JOIN n
JOIN single sa ON sa.department = pr.dept_a
JOIN single sb ON sb.department = pr.dept_b
ORDER BY lift DESC;

-- Q9. Range review candidates: items whose year-end stock would last more than a year
--     at the Q4-2025 selling pace (or that did not sell at all in Q4)
WITH q4 AS (
    SELECT f.product_key, SUM(f.qty) / 92.0 AS units_per_day
    FROM dw.fact_sales f
    WHERE f.date_key BETWEEN 20251001 AND 20251231 AND f.line_type = 'Sale'
    GROUP BY f.product_key
),
stock AS (
    SELECT product_key, SUM(qty_on_hand) AS units_on_hand, SUM(stock_value) AS stock_value
    FROM dw.fact_inventory_month_end
    WHERE snapshot_date_key = 20251231
    GROUP BY product_key
)
SELECT TOP 20 p.product_code, p.product_name, p.department, p.category,
       CAST(q4.units_per_day AS DECIMAL(8,2))                                 AS chain_units_per_day,
       s.units_on_hand,
       CAST(s.units_on_hand / NULLIF(q4.units_per_day, 0) AS DECIMAL(8,0))     AS days_of_cover,
       CAST(s.stock_value AS DECIMAL(12,0))                                   AS stock_value_sar
FROM stock s
JOIN dw.dim_product p ON p.product_key = s.product_key
LEFT JOIN q4          ON q4.product_key = s.product_key
WHERE q4.units_per_day IS NULL OR s.units_on_hand / q4.units_per_day > 365
ORDER BY s.stock_value DESC;
