/* =============================================================================
   04  Load procedures: staging -> data warehouse
   -----------------------------------------------------------------------------
   Run order is handled by dw.usp_load_all:
       dates -> locations -> suppliers -> products (+ price history)
       -> employees -> customers -> promotions -> all facts

   Cleaning rules applied here (see 05_data_quality_checks.sql for the audit):
     * codes are trimmed and upper-cased  ( ' p100123 ' -> 'P100123' )
     * text dates / numbers use TRY_CAST, so bad values become NULL, not errors
     * exact duplicate POS lines (double uploads) are loaded once
     * returns (negative qty) are kept and flagged line_type = 'Return'
     * PO lines received before they were ordered keep their row but get a
       dq_issue note and NULL lead time, so they never distort supplier KPIs
     * every sale is costed with the price-list row valid on the sale date

   Blocks between "-- @test" markers are executed by scripts/test_sql.py
   (transpiled to DuckDB) so the logic is verified outside SQL Server too.
   ============================================================================= */
USE AlShifaDW;
GO

/* ---------------------------------------------------------------- dim_date */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_date
    @from DATE = '2023-01-01',
    @to   DATE = '2026-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dw.dim_date;

    WITH d AS (
        SELECT @from AS dt
        UNION ALL
        SELECT DATEADD(DAY, 1, dt) FROM d WHERE dt < @to
    )
    INSERT INTO dw.dim_date (date_key, full_date, [year], [quarter], [month], month_name, year_month,
                             day_of_month, day_name, day_of_week_sat1, is_weekend, is_ramadan, is_eid,
                             is_public_holiday, season)
    SELECT
        YEAR(dt) * 10000 + MONTH(dt) * 100 + DAY(dt),
        dt,
        YEAR(dt),
        DATEPART(QUARTER, dt),
        MONTH(dt),
        DATENAME(MONTH, dt),
        CONCAT(YEAR(dt), '-', RIGHT('0' + CAST(MONTH(dt) AS VARCHAR(2)), 2)),
        DAY(dt),
        DATENAME(WEEKDAY, dt),
        -- independent of @@DATEFIRST: 2000-01-01 was a Saturday
        (DATEDIFF(DAY, '2000-01-01', dt) % 7) + 1,
        CASE WHEN (DATEDIFF(DAY, '2000-01-01', dt) % 7) IN (0, 6) THEN 1 ELSE 0 END,
        CASE WHEN EXISTS (SELECT 1 FROM ref.calendar_event e WHERE e.event_name = 'Ramadan'
                          AND dt BETWEEN e.start_date AND e.end_date) THEN 1 ELSE 0 END,
        CASE WHEN EXISTS (SELECT 1 FROM ref.calendar_event e WHERE e.event_name LIKE 'Eid%'
                          AND dt BETWEEN e.start_date AND e.end_date) THEN 1 ELSE 0 END,
        CASE WHEN EXISTS (SELECT 1 FROM ref.calendar_event e WHERE e.event_name <> 'Ramadan'
                          AND dt BETWEEN e.start_date AND e.end_date) THEN 1 ELSE 0 END,
        CASE WHEN MONTH(dt) IN (12, 1, 2) THEN 'Winter'
             WHEN MONTH(dt) IN (3, 4, 5)  THEN 'Spring'
             WHEN MONTH(dt) IN (6, 7, 8)  THEN 'Summer'
             ELSE 'Autumn' END
    FROM d
    OPTION (MAXRECURSION 0);
END;
GO

/* ---------------------------------------------------------------- dim_location */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_location
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.dim_location AS t
    USING (
-- @test dim_location
        SELECT UPPER(TRIM(branch_code))       AS location_code,
               TRIM(branch_name)              AS location_name,
               'Branch'                       AS location_type,
               TRIM(city)                     AS city,
               TRIM(region)                   AS region,
               TRIM(district)                 AS district,
               TRIM(branch_type)              AS branch_type,
               TRY_CAST(size_sqm AS SMALLINT) AS size_sqm,
               TRY_CAST(is_24h AS BIT)        AS is_24h,
               TRY_CAST(open_date AS DATE)    AS open_date,
               UPPER(TRIM(warehouse_code))    AS serving_warehouse_code
        FROM stg.erp_branches
        UNION ALL
        SELECT UPPER(TRIM(warehouse_code)), TRIM(warehouse_name), 'Warehouse', TRIM(city), TRIM(region),
               NULL, NULL, NULL, NULL, NULL, NULL
        FROM stg.erp_warehouses
-- @end
    ) AS s
    ON t.location_code = s.location_code
    WHEN MATCHED THEN UPDATE SET
        location_name = s.location_name, location_type = s.location_type, city = s.city, region = s.region,
        district = s.district, branch_type = s.branch_type, size_sqm = s.size_sqm, is_24h = s.is_24h,
        open_date = s.open_date, serving_warehouse_code = s.serving_warehouse_code
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (location_code, location_name, location_type, city, region, district, branch_type, size_sqm,
         is_24h, open_date, serving_warehouse_code)
        VALUES (s.location_code, s.location_name, s.location_type, s.city, s.region, s.district,
                s.branch_type, s.size_sqm, s.is_24h, s.open_date, s.serving_warehouse_code);
END;
GO

/* ---------------------------------------------------------------- dim_supplier */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_supplier
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.dim_supplier AS t
    USING (
-- @test dim_supplier
        SELECT UPPER(TRIM(supplier_code))              AS supplier_code,
               TRIM(supplier_name)                     AS supplier_name,
               TRIM(supplier_type)                     AS supplier_type,
               TRIM(city)                              AS city,
               TRY_CAST(agreed_lead_days AS SMALLINT)  AS agreed_lead_days,
               TRY_CAST(payment_terms_days AS SMALLINT) AS payment_terms_days
        FROM stg.erp_suppliers
-- @end
    ) AS s
    ON t.supplier_code = s.supplier_code
    WHEN MATCHED THEN UPDATE SET supplier_name = s.supplier_name, supplier_type = s.supplier_type,
        city = s.city, agreed_lead_days = s.agreed_lead_days, payment_terms_days = s.payment_terms_days
    WHEN NOT MATCHED BY TARGET THEN INSERT (supplier_code, supplier_name, supplier_type, city,
        agreed_lead_days, payment_terms_days)
        VALUES (s.supplier_code, s.supplier_name, s.supplier_type, s.city, s.agreed_lead_days, s.payment_terms_days);
END;
GO

/* ---------------------------------------------------------------- dim_product + price history */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_product
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.dim_product AS t
    USING (
-- @test dim_product
        SELECT UPPER(TRIM(p.product_code))                AS product_code,
               TRIM(p.product_name)                       AS product_name,
               TRIM(p.brand)                              AS brand,
               TRIM(p.department)                         AS department,
               TRIM(p.category)                           AS category,
               NULLIF(TRIM(p.sub_category), '')           AS sub_category,
               NULLIF(TRIM(p.therapeutic_class), '')      AS therapeutic_class,
               NULLIF(TRIM(p.scientific_name), '')        AS scientific_name,
               NULLIF(TRIM(p.dosage_form), '')            AS dosage_form,
               NULLIF(TRIM(p.strength), '')               AS strength,
               TRY_CAST(p.is_rx AS BIT)                   AS is_rx,
               TRY_CAST(p.is_chronic AS BIT)              AS is_chronic,
               TRY_CAST(p.is_cold_chain AS BIT)           AS is_cold_chain,
               TRY_CAST(p.is_private_label AS BIT)        AS is_private_label,
               TRY_CAST(p.shelf_life_months AS SMALLINT)  AS shelf_life_months,
               TRY_CAST(p.list_price_sar AS DECIMAL(10,2)) AS current_list_price,
               TRY_CAST(p.unit_cost_sar AS DECIMAL(10,2))  AS current_unit_cost,
               s.supplier_key,
               TRIM(p.source)                             AS data_source
        FROM stg.erp_products p
        JOIN dw.dim_supplier s ON s.supplier_code = UPPER(TRIM(p.supplier_code))
-- @end
    ) AS s
    ON t.product_code = s.product_code
    WHEN MATCHED THEN UPDATE SET
        product_name = s.product_name, brand = s.brand, department = s.department, category = s.category,
        sub_category = s.sub_category, therapeutic_class = s.therapeutic_class,
        scientific_name = s.scientific_name, dosage_form = s.dosage_form, strength = s.strength,
        is_rx = s.is_rx, is_chronic = s.is_chronic, is_cold_chain = s.is_cold_chain,
        is_private_label = s.is_private_label, shelf_life_months = s.shelf_life_months,
        current_list_price = s.current_list_price, current_unit_cost = s.current_unit_cost,
        supplier_key = s.supplier_key, data_source = s.data_source
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (product_code, product_name, brand, department, category, sub_category, therapeutic_class,
         scientific_name, dosage_form, strength, is_rx, is_chronic, is_cold_chain, is_private_label,
         shelf_life_months, current_list_price, current_unit_cost, supplier_key, data_source)
        VALUES (s.product_code, s.product_name, s.brand, s.department, s.category, s.sub_category,
                s.therapeutic_class, s.scientific_name, s.dosage_form, s.strength, s.is_rx, s.is_chronic,
                s.is_cold_chain, s.is_private_label, s.shelf_life_months, s.current_list_price,
                s.current_unit_cost, s.supplier_key, s.data_source);

    -- the current price on the product row = the open-ended price-list row
    DELETE FROM dw.dim_product_price;
-- @test dim_product_price
    INSERT INTO dw.dim_product_price (product_key, valid_from, valid_to, list_price, unit_cost)
    SELECT p.product_key,
           TRY_CAST(h.valid_from AS DATE),
           TRY_CAST(h.valid_to AS DATE),
           TRY_CAST(h.list_price_sar AS DECIMAL(10,2)),
           TRY_CAST(h.unit_cost_sar AS DECIMAL(10,2))
    FROM stg.erp_price_history h
    JOIN dw.dim_product p ON p.product_code = UPPER(TRIM(h.product_code));
-- @end

    UPDATE p SET current_list_price = pp.list_price, current_unit_cost = pp.unit_cost
    FROM dw.dim_product p
    JOIN dw.dim_product_price pp ON pp.product_key = p.product_key AND pp.valid_to = '9999-12-31';
END;
GO

/* ---------------------------------------------------------------- dim_employee */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_employee
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_employee WHERE employee_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_employee ON;
        INSERT INTO dw.dim_employee (employee_key, employee_code, full_name, gender, job_title, department, hire_date)
        VALUES (-1, 'UNKNOWN', 'Unknown employee', 'U', 'Unknown', 'Unknown', '1900-01-01');
        SET IDENTITY_INSERT dw.dim_employee OFF;
    END;

    MERGE dw.dim_employee AS t
    USING (
-- @test dim_employee
        SELECT UPPER(TRIM(e.employee_code))         AS employee_code,
               TRIM(e.full_name)                    AS full_name,
               UPPER(LEFT(TRIM(e.gender), 1))       AS gender,
               TRIM(e.job_title)                    AS job_title,
               TRIM(e.department)                   AS department,
               NULLIF(UPPER(TRIM(e.manager_code)), '') AS manager_code,
               NULLIF(TRIM(e.region), '')           AS region,
               l.location_key,
               TRY_CAST(e.hire_date AS DATE)        AS hire_date
        FROM stg.erp_employees e
        LEFT JOIN dw.dim_location l ON l.location_code = UPPER(TRIM(e.branch_code))
-- @end
    ) AS s
    ON t.employee_code = s.employee_code
    WHEN MATCHED THEN UPDATE SET full_name = s.full_name, gender = s.gender, job_title = s.job_title,
        department = s.department, manager_code = s.manager_code, region = s.region,
        location_key = s.location_key, hire_date = s.hire_date
    WHEN NOT MATCHED BY TARGET THEN INSERT (employee_code, full_name, gender, job_title, department,
        manager_code, region, location_key, hire_date)
        VALUES (s.employee_code, s.full_name, s.gender, s.job_title, s.department, s.manager_code,
                s.region, s.location_key, s.hire_date);
END;
GO

/* ---------------------------------------------------------------- dim_customer */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_customer
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_customer WHERE customer_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_customer ON;
        INSERT INTO dw.dim_customer (customer_key, customer_code, age_band, loyalty_tier)
        VALUES (-1, 'WALK-IN', 'Unknown', 'Not a member');
        SET IDENTITY_INSERT dw.dim_customer OFF;
    END;

    MERGE dw.dim_customer AS t
    USING (
-- @test dim_customer
        SELECT UPPER(TRIM(c.customer_code))      AS customer_code,
               UPPER(LEFT(TRIM(c.gender), 1))    AS gender,
               TRY_CAST(c.birth_year AS SMALLINT) AS birth_year,
               CASE WHEN 2025 - TRY_CAST(c.birth_year AS INT) < 25 THEN '18-24'
                    WHEN 2025 - TRY_CAST(c.birth_year AS INT) < 35 THEN '25-34'
                    WHEN 2025 - TRY_CAST(c.birth_year AS INT) < 45 THEN '35-44'
                    WHEN 2025 - TRY_CAST(c.birth_year AS INT) < 55 THEN '45-54'
                    WHEN 2025 - TRY_CAST(c.birth_year AS INT) < 65 THEN '55-64'
                    ELSE '65+' END               AS age_band,
               l.location_key                    AS home_location_key,
               TRIM(c.city)                      AS city,
               TRY_CAST(c.join_date AS DATE)     AS join_date,
               TRIM(c.loyalty_tier)              AS loyalty_tier,
               TRY_CAST(c.has_insurance AS BIT)  AS has_insurance
        FROM stg.crm_customers c
        LEFT JOIN dw.dim_location l ON l.location_code = UPPER(TRIM(c.home_branch_code))
-- @end
    ) AS s
    ON t.customer_code = s.customer_code
    WHEN MATCHED THEN UPDATE SET gender = s.gender, birth_year = s.birth_year, age_band = s.age_band,
        home_location_key = s.home_location_key, city = s.city, join_date = s.join_date,
        loyalty_tier = s.loyalty_tier, has_insurance = s.has_insurance
    WHEN NOT MATCHED BY TARGET THEN INSERT (customer_code, gender, birth_year, age_band, home_location_key,
        city, join_date, loyalty_tier, has_insurance)
        VALUES (s.customer_code, s.gender, s.birth_year, s.age_band, s.home_location_key, s.city,
                s.join_date, s.loyalty_tier, s.has_insurance);
END;
GO

/* ---------------------------------------------------------------- dim_promotion */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_promotion
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dw.dim_promotion WHERE promotion_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_promotion ON;
        INSERT INTO dw.dim_promotion (promotion_key, promo_code, promo_name, promo_type, discount_pct)
        VALUES (-1, 'NONE', 'No promotion', 'None', 0);
        SET IDENTITY_INSERT dw.dim_promotion OFF;
    END;

    MERGE dw.dim_promotion AS t
    USING (
-- @test dim_promotion
        SELECT UPPER(TRIM(promo_code))                AS promo_code,
               TRIM(promo_name)                       AS promo_name,
               TRIM(promo_type)                       AS promo_type,
               TRY_CAST(discount_pct AS DECIMAL(5,2)) AS discount_pct,
               TRY_CAST(start_date AS DATE)           AS start_date,
               TRY_CAST(end_date AS DATE)             AS end_date,
               NULLIF(TRIM(target_department), '')    AS target_department,
               NULLIF(TRIM(target_category), '')      AS target_category
        FROM stg.erp_promotions
-- @end
    ) AS s
    ON t.promo_code = s.promo_code
    WHEN MATCHED THEN UPDATE SET promo_name = s.promo_name, promo_type = s.promo_type,
        discount_pct = s.discount_pct, start_date = s.start_date, end_date = s.end_date,
        target_department = s.target_department, target_category = s.target_category
    WHEN NOT MATCHED BY TARGET THEN INSERT (promo_code, promo_name, promo_type, discount_pct, start_date,
        end_date, target_department, target_category)
        VALUES (s.promo_code, s.promo_name, s.promo_type, s.discount_pct, s.start_date, s.end_date,
                s.target_department, s.target_category);
END;
GO

/* ---------------------------------------------------------------- fact_sales */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_sales
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dw.fact_sales;

-- @test fact_sales
    WITH cleaned AS (
        SELECT TRIM(invoice_no)                              AS invoice_no,
               TRY_CAST(invoice_ts AS DATETIME2(0))          AS invoice_ts,
               UPPER(TRIM(branch_code))                      AS branch_code,
               UPPER(TRIM(cashier_code))                     AS cashier_code,
               NULLIF(UPPER(TRIM(customer_code)), '')        AS customer_code,
               TRIM(payment_type)                            AS payment_type,
               UPPER(TRIM(product_code))                     AS product_code,
               TRY_CAST(qty AS INT)                          AS qty,
               TRY_CAST(unit_price AS DECIMAL(10,2))         AS unit_price,
               ABS(COALESCE(TRY_CAST(discount_amount AS DECIMAL(12,2)), 0)) AS discount_abs,
               NULLIF(UPPER(TRIM(promo_code)), '')           AS promo_code
        FROM stg.pos_sales_lines
    ),
    dedup AS (
        -- the same line uploaded twice is one sale
        SELECT *, ROW_NUMBER() OVER (PARTITION BY invoice_no, product_code
                                     ORDER BY invoice_ts) AS rn
        FROM cleaned
        WHERE invoice_ts IS NOT NULL AND qty IS NOT NULL AND qty <> 0 AND unit_price IS NOT NULL
    )
    INSERT INTO dw.fact_sales (invoice_no, line_type, date_key, invoice_time, hour_of_day, location_key,
                               product_key, customer_key, employee_key, promotion_key, payment_type, qty,
                               unit_price, gross_amount, discount_amount, net_amount, cost_amount)
    SELECT s.invoice_no,
           CASE WHEN s.qty < 0 THEN 'Return' ELSE 'Sale' END,
           YEAR(s.invoice_ts) * 10000 + MONTH(s.invoice_ts) * 100 + DAY(s.invoice_ts),
           CAST(s.invoice_ts AS TIME(0)),
           DATEPART(HOUR, s.invoice_ts),
           l.location_key,
           p.product_key,
           COALESCE(c.customer_key, -1),
           COALESCE(e.employee_key, -1),
           COALESCE(pr.promotion_key, -1),
           s.payment_type,
           s.qty,
           s.unit_price,
           s.qty * s.unit_price,
           SIGN(s.qty) * s.discount_abs,
           s.qty * s.unit_price - SIGN(s.qty) * s.discount_abs,
           s.qty * pp.unit_cost
    FROM dedup s
    JOIN dw.dim_location       l  ON l.location_code = s.branch_code
    JOIN dw.dim_product        p  ON p.product_code  = s.product_code
    JOIN dw.dim_product_price  pp ON pp.product_key  = p.product_key
                                 AND CAST(s.invoice_ts AS DATE) BETWEEN pp.valid_from AND pp.valid_to
    LEFT JOIN dw.dim_customer  c  ON c.customer_code = s.customer_code
    LEFT JOIN dw.dim_employee  e  ON e.employee_code = s.cashier_code
    LEFT JOIN dw.dim_promotion pr ON pr.promo_code   = s.promo_code
    WHERE s.rn = 1;
-- @end
END;
GO

/* ---------------------------------------------------------------- fact_purchase_order_line */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_purchase_order_line
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dw.fact_purchase_order_line;

-- @test fact_purchase_order_line
    WITH po AS (
        SELECT TRIM(po_no)                          AS po_no,
               UPPER(TRIM(supplier_code))           AS supplier_code,
               UPPER(TRIM(warehouse_code))          AS warehouse_code,
               UPPER(TRIM(product_code))            AS product_code,
               TRY_CAST(order_date AS DATE)         AS order_date,
               TRY_CAST(expected_date AS DATE)      AS expected_date,
               TRY_CAST(received_date AS DATE)      AS received_date,
               TRY_CAST(qty_ordered AS INT)         AS qty_ordered,
               COALESCE(TRY_CAST(qty_received AS INT), 0) AS qty_received,
               TRY_CAST(unit_cost AS DECIMAL(10,2)) AS unit_cost,
               TRIM(status)                         AS po_status
        FROM stg.erp_purchase_orders
    )
    INSERT INTO dw.fact_purchase_order_line (po_no, supplier_key, location_key, product_key, order_date_key,
        expected_date_key, received_date_key, qty_ordered, qty_received, unit_cost, order_value,
        received_value, lead_time_days, delay_days, is_on_time, is_in_full, po_status, dq_issue)
    SELECT po.po_no,
           s.supplier_key,
           l.location_key,
           p.product_key,
           YEAR(po.order_date) * 10000 + MONTH(po.order_date) * 100 + DAY(po.order_date),
           YEAR(po.expected_date) * 10000 + MONTH(po.expected_date) * 100 + DAY(po.expected_date),
           YEAR(po.received_date) * 10000 + MONTH(po.received_date) * 100 + DAY(po.received_date),
           po.qty_ordered,
           po.qty_received,
           po.unit_cost,
           po.qty_ordered * po.unit_cost,
           po.qty_received * po.unit_cost,
           CASE WHEN po.received_date >= po.order_date THEN DATEDIFF(DAY, po.order_date, po.received_date) END,
           CASE WHEN po.received_date >= po.order_date THEN DATEDIFF(DAY, po.expected_date, po.received_date) END,
           CASE WHEN po.received_date IS NULL OR po.received_date < po.order_date THEN NULL
                WHEN po.received_date <= po.expected_date THEN 1 ELSE 0 END,
           CASE WHEN po.received_date IS NULL OR po.received_date < po.order_date THEN NULL
                WHEN po.qty_received >= po.qty_ordered THEN 1 ELSE 0 END,
           po.po_status,
           CASE WHEN po.received_date < po.order_date THEN 'Received date before order date' END
    FROM po
    JOIN dw.dim_supplier s ON s.supplier_code = po.supplier_code
    JOIN dw.dim_location l ON l.location_code = po.warehouse_code
    JOIN dw.dim_product  p ON p.product_code  = po.product_code
    WHERE po.order_date IS NOT NULL AND po.qty_ordered IS NOT NULL;
-- @end
END;
GO

/* ---------------------------------------------------------------- warehouse & inventory facts */
CREATE OR ALTER PROCEDURE dw.usp_load_inventory_facts
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dw.fact_branch_transfer;
    TRUNCATE TABLE dw.fact_inventory_month_end;
    TRUNCATE TABLE dw.fact_inventory_batch;
    TRUNCATE TABLE dw.fact_stockout_event;
    TRUNCATE TABLE dw.fact_writeoff;

-- @test fact_branch_transfer
    INSERT INTO dw.fact_branch_transfer (transfer_no, from_location_key, to_location_key, product_key,
        request_date_key, ship_date_key, qty_requested, qty_shipped)
    SELECT TRIM(t.transfer_no),
           w.location_key,
           b.location_key,
           p.product_key,
           YEAR(TRY_CAST(t.request_date AS DATE)) * 10000 + MONTH(TRY_CAST(t.request_date AS DATE)) * 100 + DAY(TRY_CAST(t.request_date AS DATE)),
           YEAR(TRY_CAST(t.ship_date AS DATE)) * 10000 + MONTH(TRY_CAST(t.ship_date AS DATE)) * 100 + DAY(TRY_CAST(t.ship_date AS DATE)),
           TRY_CAST(t.qty_requested AS INT),
           TRY_CAST(t.qty_shipped AS INT)
    FROM stg.wms_transfers_to_branches t
    JOIN dw.dim_location w ON w.location_code = UPPER(TRIM(t.warehouse_code))
    JOIN dw.dim_location b ON b.location_code = UPPER(TRIM(t.branch_code))
    JOIN dw.dim_product  p ON p.product_code  = UPPER(TRIM(t.product_code));
-- @end

-- @test fact_inventory_month_end
    INSERT INTO dw.fact_inventory_month_end (snapshot_date_key, location_key, product_key, qty_on_hand,
                                             unit_cost, stock_value)
    SELECT YEAR(i.snap) * 10000 + MONTH(i.snap) * 100 + DAY(i.snap),
           l.location_key,
           p.product_key,
           i.qty,
           pp.unit_cost,
           i.qty * pp.unit_cost
    FROM (SELECT TRY_CAST(snapshot_date AS DATE) AS snap,
                 UPPER(TRIM(location_code))      AS location_code,
                 UPPER(TRIM(product_code))       AS product_code,
                 TRY_CAST(qty_on_hand AS INT)    AS qty
          FROM stg.wms_inventory_month_end) i
    JOIN dw.dim_location      l  ON l.location_code = i.location_code
    JOIN dw.dim_product       p  ON p.product_code  = i.product_code
    JOIN dw.dim_product_price pp ON pp.product_key  = p.product_key AND i.snap BETWEEN pp.valid_from AND pp.valid_to
    WHERE i.qty > 0;
-- @end

-- @test fact_inventory_batch
    INSERT INTO dw.fact_inventory_batch (snapshot_date_key, location_key, product_key, batch_no, received_date,
                                         expiry_date, qty_on_hand, stock_value, days_to_expiry)
    SELECT 20251231,
           l.location_key,
           p.product_key,
           TRIM(b.batch_no),
           TRY_CAST(b.received_date AS DATE),
           TRY_CAST(b.expiry_date AS DATE),
           TRY_CAST(b.qty_on_hand AS INT),
           TRY_CAST(b.qty_on_hand AS INT) * p.current_unit_cost,
           DATEDIFF(DAY, CAST('2025-12-31' AS DATE), TRY_CAST(b.expiry_date AS DATE))
    FROM stg.wms_batches_current b
    JOIN dw.dim_location l ON l.location_code = UPPER(TRIM(b.location_code))
    JOIN dw.dim_product  p ON p.product_code  = UPPER(TRIM(b.product_code));
-- @end

-- @test fact_stockout_event
    INSERT INTO dw.fact_stockout_event (location_key, product_key, start_date_key, end_date_key, days_out, reason)
    SELECT l.location_key,
           p.product_key,
           YEAR(x.d1) * 10000 + MONTH(x.d1) * 100 + DAY(x.d1),
           YEAR(x.d2) * 10000 + MONTH(x.d2) * 100 + DAY(x.d2),
           DATEDIFF(DAY, x.d1, x.d2) + 1,
           x.reason
    FROM (SELECT UPPER(TRIM(branch_code)) AS branch_code, UPPER(TRIM(product_code)) AS product_code,
                 TRY_CAST(out_of_stock_from AS DATE) AS d1, TRY_CAST(back_in_stock_on AS DATE) AS d2,
                 TRIM(reason) AS reason
          FROM stg.wms_stockout_events) x
    JOIN dw.dim_location l ON l.location_code = x.branch_code
    JOIN dw.dim_product  p ON p.product_code  = x.product_code;
-- @end

-- @test fact_writeoff
    INSERT INTO dw.fact_writeoff (date_key, location_key, product_key, qty, cost_value, reason)
    SELECT YEAR(x.d) * 10000 + MONTH(x.d) * 100 + DAY(x.d),
           l.location_key,
           p.product_key,
           x.qty,
           x.qty * pp.unit_cost,
           x.reason
    FROM (SELECT TRY_CAST(writeoff_date AS DATE) AS d, UPPER(TRIM(location_code)) AS location_code,
                 UPPER(TRIM(product_code)) AS product_code, TRY_CAST(qty AS INT) AS qty, TRIM(reason) AS reason
          FROM stg.wms_expiry_writeoffs) x
    JOIN dw.dim_location      l  ON l.location_code = x.location_code
    JOIN dw.dim_product       p  ON p.product_code  = x.product_code
    JOIN dw.dim_product_price pp ON pp.product_key  = p.product_key AND x.d BETWEEN pp.valid_from AND pp.valid_to;
-- @end
END;
GO

/* ---------------------------------------------------------------- run everything */
CREATE OR ALTER PROCEDURE dw.usp_load_all
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2 = SYSDATETIME();
    EXEC dw.usp_load_dim_date;                    PRINT 'dim_date done';
    EXEC dw.usp_load_dim_location;                PRINT 'dim_location done';
    EXEC dw.usp_load_dim_supplier;                PRINT 'dim_supplier done';
    EXEC dw.usp_load_dim_product;                 PRINT 'dim_product done';
    EXEC dw.usp_load_dim_employee;                PRINT 'dim_employee done';
    EXEC dw.usp_load_dim_customer;                PRINT 'dim_customer done';
    EXEC dw.usp_load_dim_promotion;               PRINT 'dim_promotion done';
    EXEC dw.usp_load_fact_sales;                  PRINT 'fact_sales done';
    EXEC dw.usp_load_fact_purchase_order_line;    PRINT 'fact_purchase_order_line done';
    EXEC dw.usp_load_inventory_facts;             PRINT 'inventory facts done';
    PRINT CONCAT('Full load finished in ', DATEDIFF(SECOND, @t0, SYSDATETIME()), ' seconds');
END;
GO

-- EXEC dw.usp_load_all;
