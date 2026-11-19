/* =============================================================================
   03  Data warehouse tables (star schema)
   -----------------------------------------------------------------------------
   Conformed dimensions are shared by every department's fact table, so a
   product, branch or date means the same thing in sales, purchasing and
   inventory reports.

   Phase 1 facts : sales, purchase orders, DC-to-branch transfers,
                   month-end inventory, batches on hand, stock-outs, write-offs
   Later phases  : HR, training, online, insurance, customer service, finance,
                   quality and maintenance plug into the same dimensions.

   Surrogate keys : INT IDENTITY.  Unknown member : key -1 / 0 where useful.
   ============================================================================= */
USE AlShifaDW;
GO

DROP TABLE IF EXISTS dw.fact_sales, dw.fact_purchase_order_line, dw.fact_branch_transfer,
                     dw.fact_inventory_month_end, dw.fact_inventory_batch, dw.fact_stockout_event,
                     dw.fact_writeoff;
DROP TABLE IF EXISTS dw.dim_product_price, dw.dim_product, dw.dim_supplier, dw.dim_location,
                     dw.dim_employee, dw.dim_customer, dw.dim_promotion, dw.dim_date, ref.calendar_event;
GO

-- ============================================================ reference data
CREATE TABLE ref.calendar_event (
    event_name   NVARCHAR(50) NOT NULL,
    start_date   DATE         NOT NULL,
    end_date     DATE         NOT NULL,
    CONSTRAINT pk_calendar_event PRIMARY KEY (event_name, start_date)
);
INSERT INTO ref.calendar_event (event_name, start_date, end_date) VALUES
    (N'Ramadan',       '2024-03-11', '2024-04-09'),
    (N'Eid al-Fitr',   '2024-04-10', '2024-04-13'),
    (N'Eid al-Adha',   '2024-06-16', '2024-06-19'),
    (N'National Day',  '2024-09-23', '2024-09-23'),
    (N'Founding Day',  '2024-02-22', '2024-02-22'),
    (N'Ramadan',       '2025-03-01', '2025-03-29'),
    (N'Eid al-Fitr',   '2025-03-30', '2025-04-02'),
    (N'Eid al-Adha',   '2025-06-06', '2025-06-09'),
    (N'National Day',  '2025-09-23', '2025-09-23'),
    (N'Founding Day',  '2025-02-22', '2025-02-22');
GO

-- ============================================================ dimensions
CREATE TABLE dw.dim_date (
    date_key          INT          NOT NULL PRIMARY KEY,   -- yyyymmdd
    full_date         DATE         NOT NULL UNIQUE,
    [year]            SMALLINT     NOT NULL,
    [quarter]         TINYINT      NOT NULL,
    [month]           TINYINT      NOT NULL,
    month_name        NVARCHAR(10) NOT NULL,
    year_month        CHAR(7)      NOT NULL,               -- 2025-03
    day_of_month      TINYINT      NOT NULL,
    day_name          NVARCHAR(10) NOT NULL,
    day_of_week_sat1  TINYINT      NOT NULL,               -- Saudi week: Sat = 1 ... Fri = 7
    is_weekend        BIT          NOT NULL,               -- Friday & Saturday
    is_ramadan        BIT          NOT NULL,
    is_eid            BIT          NOT NULL,
    is_public_holiday BIT          NOT NULL,
    season            NVARCHAR(10) NOT NULL
);

CREATE TABLE dw.dim_location (
    location_key   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    location_code  NVARCHAR(20)  NOT NULL UNIQUE,
    location_name  NVARCHAR(200) NOT NULL,
    location_type  NVARCHAR(20)  NOT NULL,                 -- Branch | Warehouse
    city           NVARCHAR(100) NOT NULL,
    region         NVARCHAR(50)  NOT NULL,
    district       NVARCHAR(100) NULL,
    branch_type    NVARCHAR(30)  NULL,                     -- Street | Residential | Mall | Hospital | Highway
    size_sqm       SMALLINT      NULL,
    is_24h         BIT           NULL,
    open_date      DATE          NULL,
    serving_warehouse_code NVARCHAR(20) NULL
);

CREATE TABLE dw.dim_supplier (
    supplier_key       INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    supplier_code      NVARCHAR(20)  NOT NULL UNIQUE,
    supplier_name      NVARCHAR(200) NOT NULL,
    supplier_type      NVARCHAR(30)  NOT NULL,
    city               NVARCHAR(100) NOT NULL,
    agreed_lead_days   SMALLINT      NOT NULL,
    payment_terms_days SMALLINT      NOT NULL
);

CREATE TABLE dw.dim_product (
    product_key        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    product_code       NVARCHAR(20)  NOT NULL UNIQUE,
    product_name       NVARCHAR(300) NOT NULL,
    brand              NVARCHAR(100) NOT NULL,
    department         NVARCHAR(100) NOT NULL,
    category           NVARCHAR(100) NOT NULL,
    sub_category       NVARCHAR(100) NULL,
    therapeutic_class  NVARCHAR(100) NULL,
    scientific_name    NVARCHAR(300) NULL,
    dosage_form        NVARCHAR(150) NULL,
    strength           NVARCHAR(50)  NULL,
    is_rx              BIT NOT NULL,
    is_chronic         BIT NOT NULL,
    is_cold_chain      BIT NOT NULL,
    is_private_label   BIT NOT NULL,
    shelf_life_months  SMALLINT NOT NULL,
    current_list_price DECIMAL(10,2) NOT NULL,
    current_unit_cost  DECIMAL(10,2) NOT NULL,
    supplier_key       INT NOT NULL REFERENCES dw.dim_supplier(supplier_key),
    data_source        NVARCHAR(100) NOT NULL
);

-- price list history (type 2 style validity ranges) used to cost every sale
CREATE TABLE dw.dim_product_price (
    product_key    INT  NOT NULL REFERENCES dw.dim_product(product_key),
    valid_from     DATE NOT NULL,
    valid_to       DATE NOT NULL,
    list_price     DECIMAL(10,2) NOT NULL,
    unit_cost      DECIMAL(10,2) NOT NULL,
    CONSTRAINT pk_dim_product_price PRIMARY KEY (product_key, valid_from)
);

CREATE TABLE dw.dim_employee (
    employee_key   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    employee_code  NVARCHAR(20)  NOT NULL UNIQUE,
    full_name      NVARCHAR(200) NOT NULL,
    gender         CHAR(1)       NOT NULL,
    job_title      NVARCHAR(100) NOT NULL,
    department     NVARCHAR(100) NOT NULL,
    manager_code   NVARCHAR(20)  NULL,
    region         NVARCHAR(50)  NULL,
    location_key   INT NULL REFERENCES dw.dim_location(location_key),
    hire_date      DATE NOT NULL
);

CREATE TABLE dw.dim_customer (
    customer_key      INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    customer_code     NVARCHAR(20) NOT NULL UNIQUE,
    gender            CHAR(1)      NULL,
    birth_year        SMALLINT     NULL,
    age_band          NVARCHAR(10) NULL,
    home_location_key INT NULL REFERENCES dw.dim_location(location_key),
    city              NVARCHAR(100) NULL,
    join_date         DATE NULL,
    loyalty_tier      NVARCHAR(20) NULL,
    has_insurance     BIT NULL
);

CREATE TABLE dw.dim_promotion (
    promotion_key      INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    promo_code         NVARCHAR(20)  NOT NULL UNIQUE,
    promo_name         NVARCHAR(200) NOT NULL,
    promo_type         NVARCHAR(50)  NOT NULL,
    discount_pct       DECIMAL(5,2)  NOT NULL,
    start_date         DATE NULL,
    end_date           DATE NULL,
    target_department  NVARCHAR(100) NULL,
    target_category    NVARCHAR(100) NULL
);
GO

-- ============================================================ facts
-- Sales: one row per invoice line. Returns are negative quantities.
CREATE TABLE dw.fact_sales (
    sales_line_id    BIGINT IDENTITY(1,1) NOT NULL,
    invoice_no       NVARCHAR(30)  NOT NULL,
    line_type        NVARCHAR(10)  NOT NULL,             -- Sale | Return
    date_key         INT           NOT NULL,
    invoice_time     TIME(0)       NOT NULL,
    hour_of_day      TINYINT       NOT NULL,
    location_key     INT           NOT NULL,
    product_key      INT           NOT NULL,
    customer_key     INT           NOT NULL,             -- -1 = walk-in (no loyalty card)
    employee_key     INT           NOT NULL,
    promotion_key    INT           NOT NULL,             -- -1 = no promotion
    payment_type     NVARCHAR(20)  NOT NULL,
    qty              INT           NOT NULL,
    unit_price       DECIMAL(10,2) NOT NULL,
    gross_amount     DECIMAL(12,2) NOT NULL,
    discount_amount  DECIMAL(12,2) NOT NULL,
    net_amount       DECIMAL(12,2) NOT NULL,
    cost_amount      DECIMAL(12,2) NOT NULL
);

CREATE TABLE dw.fact_purchase_order_line (
    po_line_id         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    po_no              NVARCHAR(20) NOT NULL,
    supplier_key       INT NOT NULL,
    location_key       INT NOT NULL,                     -- receiving warehouse
    product_key        INT NOT NULL,
    order_date_key     INT NOT NULL,
    expected_date_key  INT NOT NULL,
    received_date_key  INT NULL,
    qty_ordered        INT NOT NULL,
    qty_received       INT NOT NULL,
    unit_cost          DECIMAL(10,2) NOT NULL,
    order_value        DECIMAL(14,2) NOT NULL,
    received_value     DECIMAL(14,2) NOT NULL,
    lead_time_days     SMALLINT NULL,
    delay_days         SMALLINT NULL,
    is_on_time         BIT NULL,
    is_in_full         BIT NULL,
    po_status          NVARCHAR(20) NOT NULL,
    dq_issue           NVARCHAR(100) NULL                -- data quality note, e.g. received before ordered
);

CREATE TABLE dw.fact_branch_transfer (
    transfer_line_id   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    transfer_no        NVARCHAR(20) NOT NULL,
    from_location_key  INT NOT NULL,
    to_location_key    INT NOT NULL,
    product_key        INT NOT NULL,
    request_date_key   INT NOT NULL,
    ship_date_key      INT NOT NULL,
    qty_requested      INT NOT NULL,
    qty_shipped        INT NOT NULL
);

CREATE TABLE dw.fact_inventory_month_end (
    snapshot_date_key  INT NOT NULL,
    location_key       INT NOT NULL,
    product_key        INT NOT NULL,
    qty_on_hand        INT NOT NULL,
    unit_cost          DECIMAL(10,2) NOT NULL,
    stock_value        DECIMAL(14,2) NOT NULL,
    CONSTRAINT pk_fact_inventory_month_end PRIMARY KEY (snapshot_date_key, location_key, product_key)
);

CREATE TABLE dw.fact_inventory_batch (
    snapshot_date_key  INT NOT NULL,
    location_key       INT NOT NULL,
    product_key        INT NOT NULL,
    batch_no           NVARCHAR(30) NOT NULL,
    received_date      DATE NOT NULL,
    expiry_date        DATE NOT NULL,
    qty_on_hand        INT  NOT NULL,
    stock_value        DECIMAL(14,2) NOT NULL,
    days_to_expiry     INT  NOT NULL,
    CONSTRAINT pk_fact_inventory_batch PRIMARY KEY (snapshot_date_key, location_key, product_key, batch_no)
);

CREATE TABLE dw.fact_stockout_event (
    stockout_id        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    location_key       INT NOT NULL,
    product_key        INT NOT NULL,
    start_date_key     INT NOT NULL,
    end_date_key       INT NOT NULL,
    days_out           SMALLINT NOT NULL,
    reason             NVARCHAR(50) NOT NULL
);

CREATE TABLE dw.fact_writeoff (
    writeoff_id        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    date_key           INT NOT NULL,
    location_key       INT NOT NULL,
    product_key        INT NOT NULL,
    qty                INT NOT NULL,
    cost_value         DECIMAL(12,2) NOT NULL,
    reason             NVARCHAR(50) NOT NULL
);
GO

-- Columnstore for the big fact table: fast aggregations, ~10x compression
CREATE CLUSTERED COLUMNSTORE INDEX cci_fact_sales ON dw.fact_sales;
GO
