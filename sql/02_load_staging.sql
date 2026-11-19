/* =============================================================================
   02  Load the CSV extracts into staging
   -----------------------------------------------------------------------------
   1. Run scripts/generate_data.py to create the CSV files.
   2. Set @root below to the folder that contains erp, crm, pos and wms.
      The SQL Server service account must be able to read that folder
      (a folder like C:\AlShifaData\generated is the easiest choice).
   3. Run this script. It truncates staging and reloads every extract.
   ============================================================================= */
USE AlShifaDW;
GO

DECLARE @root NVARCHAR(400) = N'C:\AlShifaData\generated\';   -- <== change me

DECLARE @files TABLE (stg_table SYSNAME, rel_path NVARCHAR(200));
INSERT INTO @files VALUES
    (N'stg.erp_branches',            N'erp\branches.csv'),
    (N'stg.erp_warehouses',          N'erp\warehouses.csv'),
    (N'stg.erp_suppliers',           N'erp\suppliers.csv'),
    (N'stg.erp_products',            N'erp\products.csv'),
    (N'stg.erp_price_history',       N'erp\price_history.csv'),
    (N'stg.erp_employees',           N'erp\employees.csv'),
    (N'stg.erp_promotions',          N'erp\promotions.csv'),
    (N'stg.erp_purchase_orders',     N'erp\purchase_orders.csv'),
    (N'stg.crm_customers',           N'crm\customers.csv'),
    (N'stg.wms_transfers_to_branches', N'wms\transfers_to_branches.csv'),
    (N'stg.wms_inventory_month_end', N'wms\inventory_month_end.csv'),
    (N'stg.wms_batches_current',     N'wms\batches_current.csv'),
    (N'stg.wms_expiry_writeoffs',    N'wms\expiry_writeoffs.csv'),
    (N'stg.wms_stockout_events',     N'wms\stockout_events.csv');

-- POS delivers one file per month: sales_lines_2024_01.csv ... sales_lines_2025_12.csv
DECLARE @m DATE = '2024-01-01';
WHILE @m <= '2025-12-01'
BEGIN
    INSERT INTO @files VALUES (N'stg.pos_sales_lines',
        N'pos\sales_lines_' + CONVERT(NCHAR(4), YEAR(@m)) + N'_' + RIGHT(N'0' + CONVERT(NVARCHAR(2), MONTH(@m)), 2) + N'.csv');
    SET @m = DATEADD(MONTH, 1, @m);
END;

-- empty every staging table once
DECLARE @t SYSNAME, @p NVARCHAR(200), @sql NVARCHAR(MAX), @rc INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT stg_table FROM @files;
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC (N'TRUNCATE TABLE ' + @t);
    FETCH NEXT FROM c INTO @t;
END;
CLOSE c; DEALLOCATE c;

-- bulk load every file
DECLARE f CURSOR LOCAL FAST_FORWARD FOR SELECT stg_table, rel_path FROM @files;
OPEN f; FETCH NEXT FROM f INTO @t, @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'BULK INSERT ' + @t + N' FROM ''' + @root + @p + N''' WITH (
                    FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'', CODEPAGE = ''65001'',
                    ROWTERMINATOR = ''0x0a'', KEEPNULLS, TABLOCK, BATCHSIZE = 500000);
                 SET @rc = @@ROWCOUNT;';
    EXEC sp_executesql @sql, N'@rc INT OUTPUT', @rc = @rc OUTPUT;
    PRINT CONCAT(@t, N'  <=  ', @p, N'  (', @rc, N' rows)');
    FETCH NEXT FROM f INTO @t, @p;
END;
CLOSE f; DEALLOCATE f;
GO

-- row counts per staging table
SELECT s.name + '.' + t.name AS staging_table, SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE s.name = 'stg'
GROUP BY s.name, t.name
ORDER BY staging_table;
GO
