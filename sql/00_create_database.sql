/* =============================================================================
   Al Shifa Al Ajil Pharmacies - Enterprise Data Warehouse
   00  Create database and schemas
   -----------------------------------------------------------------------------
   Target : SQL Server 2019 or later (Developer / Express edition is enough)
   Schemas:
       stg   raw extracts exactly as delivered by the source systems (all text)
       ref   hand-maintained reference data (calendar events, ...)
       dw    cleaned star schema: conformed dimensions + one fact per process
       mart  business-friendly views for Power BI and ad-hoc analysis
   ============================================================================= */

IF DB_ID(N'AlShifaDW') IS NULL
    CREATE DATABASE AlShifaDW;
GO

USE AlShifaDW;
GO

-- Simple recovery keeps the log small during bulk loads on a laptop
ALTER DATABASE AlShifaDW SET RECOVERY SIMPLE;
GO

IF SCHEMA_ID(N'stg')  IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'ref')  IS NULL EXEC (N'CREATE SCHEMA ref');
IF SCHEMA_ID(N'dw')   IS NULL EXEC (N'CREATE SCHEMA dw');
IF SCHEMA_ID(N'mart') IS NULL EXEC (N'CREATE SCHEMA mart');
GO
