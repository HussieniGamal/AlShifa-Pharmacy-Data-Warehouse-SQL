/* =============================================================================
   01  Staging tables
   -----------------------------------------------------------------------------
   One table per source extract. Every column is NVARCHAR on purpose: staging
   must accept whatever the source sends (bad dates, padded codes, ...).
   Typing, trimming and validation happen in the load procedures (04).
   ============================================================================= */
USE AlShifaDW;
GO

DROP TABLE IF EXISTS stg.erp_branches, stg.erp_warehouses, stg.erp_suppliers, stg.erp_products,
                     stg.erp_price_history, stg.erp_employees, stg.erp_promotions, stg.erp_purchase_orders,
                     stg.crm_customers, stg.pos_sales_lines, stg.wms_transfers_to_branches,
                     stg.wms_inventory_month_end, stg.wms_batches_current, stg.wms_expiry_writeoffs,
                     stg.wms_stockout_events;
GO

-- ---------------------------------------------------------------- ERP masters
CREATE TABLE stg.erp_branches (
    branch_code NVARCHAR(50), city NVARCHAR(100), region NVARCHAR(50), district NVARCHAR(100),
    branch_type NVARCHAR(50), size_sqm NVARCHAR(20), open_date NVARCHAR(30), is_24h NVARCHAR(10),
    warehouse_code NVARCHAR(50), branch_name NVARCHAR(200));

CREATE TABLE stg.erp_warehouses (
    warehouse_code NVARCHAR(50), warehouse_name NVARCHAR(200), city NVARCHAR(100), region NVARCHAR(50));

CREATE TABLE stg.erp_suppliers (
    supplier_code NVARCHAR(50), supplier_name NVARCHAR(200), supplier_type NVARCHAR(50), city NVARCHAR(100),
    agreed_lead_days NVARCHAR(10), payment_terms_days NVARCHAR(10));

CREATE TABLE stg.erp_products (
    product_code NVARCHAR(50), product_name NVARCHAR(300), brand NVARCHAR(100), department NVARCHAR(100),
    category NVARCHAR(100), sub_category NVARCHAR(100), therapeutic_class NVARCHAR(100),
    scientific_name NVARCHAR(300), dosage_form NVARCHAR(150), strength NVARCHAR(50), is_rx NVARCHAR(10),
    is_chronic NVARCHAR(10), is_cold_chain NVARCHAR(10), list_price_sar NVARCHAR(30), source NVARCHAR(100),
    is_private_label NVARCHAR(10), unit_cost_sar NVARCHAR(30), shelf_life_months NVARCHAR(10),
    supplier_code NVARCHAR(50));

CREATE TABLE stg.erp_price_history (
    product_code NVARCHAR(50), valid_from NVARCHAR(30), valid_to NVARCHAR(30),
    list_price_sar NVARCHAR(30), unit_cost_sar NVARCHAR(30));

CREATE TABLE stg.erp_employees (
    employee_code NVARCHAR(50), full_name NVARCHAR(200), gender NVARCHAR(10), job_title NVARCHAR(100),
    department NVARCHAR(100), manager_code NVARCHAR(50), region NVARCHAR(50), branch_code NVARCHAR(50),
    hire_date NVARCHAR(30));

CREATE TABLE stg.erp_promotions (
    promo_code NVARCHAR(50), promo_name NVARCHAR(200), promo_type NVARCHAR(50), discount_pct NVARCHAR(20),
    start_date NVARCHAR(30), end_date NVARCHAR(30), target_department NVARCHAR(100), target_category NVARCHAR(100));

CREATE TABLE stg.erp_purchase_orders (
    po_no NVARCHAR(50), supplier_code NVARCHAR(50), warehouse_code NVARCHAR(50), order_date NVARCHAR(30),
    expected_date NVARCHAR(30), received_date NVARCHAR(30), product_code NVARCHAR(50),
    qty_ordered NVARCHAR(20), qty_received NVARCHAR(20), unit_cost NVARCHAR(30), status NVARCHAR(30));

-- ---------------------------------------------------------------- CRM
CREATE TABLE stg.crm_customers (
    customer_code NVARCHAR(50), gender NVARCHAR(10), birth_year NVARCHAR(10), home_branch_code NVARCHAR(50),
    join_date NVARCHAR(30), loyalty_tier NVARCHAR(20), has_insurance NVARCHAR(10), city NVARCHAR(100));

-- ---------------------------------------------------------------- POS
CREATE TABLE stg.pos_sales_lines (
    invoice_no NVARCHAR(50), invoice_ts NVARCHAR(40), branch_code NVARCHAR(50), cashier_code NVARCHAR(50),
    customer_code NVARCHAR(50), payment_type NVARCHAR(30), product_code NVARCHAR(50), qty NVARCHAR(20),
    unit_price NVARCHAR(30), discount_amount NVARCHAR(30), promo_code NVARCHAR(50));

-- ---------------------------------------------------------------- WMS
CREATE TABLE stg.wms_transfers_to_branches (
    transfer_no NVARCHAR(50), warehouse_code NVARCHAR(50), branch_code NVARCHAR(50), request_date NVARCHAR(30),
    ship_date NVARCHAR(30), product_code NVARCHAR(50), qty_requested NVARCHAR(20), qty_shipped NVARCHAR(20));

CREATE TABLE stg.wms_inventory_month_end (
    snapshot_date NVARCHAR(30), location_code NVARCHAR(50), product_code NVARCHAR(50), qty_on_hand NVARCHAR(20));

CREATE TABLE stg.wms_batches_current (
    location_code NVARCHAR(50), product_code NVARCHAR(50), batch_no NVARCHAR(50), received_date NVARCHAR(30),
    expiry_date NVARCHAR(30), qty_on_hand NVARCHAR(20));

CREATE TABLE stg.wms_expiry_writeoffs (
    writeoff_date NVARCHAR(30), location_code NVARCHAR(50), product_code NVARCHAR(50), qty NVARCHAR(20),
    reason NVARCHAR(100));

CREATE TABLE stg.wms_stockout_events (
    branch_code NVARCHAR(50), product_code NVARCHAR(50), out_of_stock_from NVARCHAR(30),
    back_in_stock_on NVARCHAR(30), reason NVARCHAR(100));
GO
