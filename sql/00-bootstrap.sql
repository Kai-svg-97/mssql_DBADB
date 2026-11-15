USE master;
GO
SET NOCOUNT ON;
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
    THROW 51000, 'DBADB deployment requires sysadmin.', 1;
IF TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) < 15
    THROW 51000, 'SQL Server 2019 or later is required.', 1;
IF DB_ID(N'DBADB') IS NULL EXEC(N'CREATE DATABASE DBADB;');
GO
USE DBADB;
GO
IF OBJECT_ID(N'cfg.SchemaVersion', N'U') IS NOT NULL
    EXEC(N'IF EXISTS (SELECT 1 FROM cfg.SchemaVersion WHERE version > 3)
        THROW 51000, ''This database requires a newer deployment package.'', 1;');
GO
IF SCHEMA_ID(N'cfg') IS NULL EXEC(N'CREATE SCHEMA cfg AUTHORIZATION dbo;');
IF SCHEMA_ID(N'ops') IS NULL EXEC(N'CREATE SCHEMA ops AUTHORIZATION dbo;');
IF SCHEMA_ID(N'collect') IS NULL EXEC(N'CREATE SCHEMA collect AUTHORIZATION dbo;');
IF SCHEMA_ID(N'report') IS NULL EXEC(N'CREATE SCHEMA report AUTHORIZATION dbo;');
GO
