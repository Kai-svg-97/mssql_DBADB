-- DESTRUCTIVE TEST FIXTURE: disposable instance only. Run through tests/run.py.
-- Recreates the v1 (schema version 1) DBADB tables with operator data, so install.sql is
-- exercised as an in-place v1 -> v2 upgrade (ALTER TABLE ADD on populated tables).
-- The DDL below is the released v1 schema; do not edit it to match later versions.
:On Error exit
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
IF SCHEMA_ID(N'cfg') IS NULL EXEC(N'CREATE SCHEMA cfg AUTHORIZATION dbo;');
IF SCHEMA_ID(N'ops') IS NULL EXEC(N'CREATE SCHEMA ops AUTHORIZATION dbo;');
IF SCHEMA_ID(N'collect') IS NULL EXEC(N'CREATE SCHEMA collect AUTHORIZATION dbo;');
IF SCHEMA_ID(N'report') IS NULL EXEC(N'CREATE SCHEMA report AUTHORIZATION dbo;');
GO
USE DBADB;
GO
IF OBJECT_ID(N'cfg.SchemaVersion', N'U') IS NULL
CREATE TABLE cfg.SchemaVersion (
    version int NOT NULL PRIMARY KEY,
    installed_at datetime2(0) NOT NULL DEFAULT SYSDATETIME()
);
IF OBJECT_ID(N'cfg.BackupDefault', N'U') IS NULL
CREATE TABLE cfg.BackupDefault (
    database_scope varchar(6) NOT NULL CHECK (database_scope IN ('USER','SYSTEM')),
    backup_type char(1) NOT NULL CHECK (backup_type IN ('D','I','L')),
    enabled bit NOT NULL,
    directory nvarchar(1000) NULL,
    interval_minutes int NOT NULL CHECK (interval_minutes BETWEEN 1 AND 525600),
    start_time time(0) NOT NULL CHECK (DATEPART(second,start_time)=0),
    retention_days int NOT NULL CHECK (retention_days BETWEEN 1 AND 36500),
    compression bit NOT NULL DEFAULT 1,
    checksum bit NOT NULL DEFAULT 1,
    copy_only bit NOT NULL DEFAULT 0,
    CONSTRAINT PK_BackupDefault PRIMARY KEY(database_scope, backup_type),
    CONSTRAINT CK_DefaultCopyOnly CHECK (copy_only = 0 OR backup_type = 'D')
);
IF OBJECT_ID(N'cfg.BackupOverride', N'U') IS NULL
CREATE TABLE cfg.BackupOverride (
    database_name sysname NOT NULL,
    backup_type char(1) NOT NULL CHECK (backup_type IN ('D','I','L')),
    enabled bit NULL,
    directory nvarchar(1000) NULL,
    interval_minutes int NULL CHECK (interval_minutes BETWEEN 1 AND 525600),
    start_time time(0) NULL CHECK (DATEPART(second,start_time)=0),
    retention_days int NULL CHECK (retention_days BETWEEN 1 AND 36500),
    compression bit NULL,
    checksum bit NULL,
    copy_only bit NULL,
    note nvarchar(1000) NULL,
    CONSTRAINT PK_BackupOverride PRIMARY KEY(database_name, backup_type),
    CONSTRAINT CK_OverrideCopyOnly CHECK (copy_only = 0 OR copy_only IS NULL OR backup_type = 'D')
);
IF OBJECT_ID(N'cfg.AgentJob', N'U') IS NULL
CREATE TABLE cfg.AgentJob (
    job_key varchar(30) NOT NULL PRIMARY KEY,
    job_id uniqueidentifier NOT NULL UNIQUE
);
-- Insert only missing defaults, never overwrite operator choices during upgrades.
INSERT cfg.BackupDefault(database_scope, backup_type, enabled, interval_minutes, start_time, retention_days)
SELECT s.database_scope, s.backup_type, s.enabled, s.interval_minutes, s.start_time, s.retention_days
FROM (VALUES
    ('USER','D',1,1440,CAST('02:00' AS time),14),
    ('USER','I',0,1440,CAST('14:00' AS time),14),
    ('USER','L',1,15,CAST('00:00' AS time),7),
    ('SYSTEM','D',1,1440,CAST('01:00' AS time),14),
    ('SYSTEM','I',0,1440,CAST('01:00' AS time),14),
    ('SYSTEM','L',0,15,CAST('00:00' AS time),7)
) s(database_scope,backup_type,enabled,interval_minutes,start_time,retention_days)
WHERE NOT EXISTS (SELECT 1 FROM cfg.BackupDefault t
    WHERE t.database_scope=s.database_scope AND t.backup_type=s.backup_type);
GO
IF OBJECT_ID(N'ops.BackupRun', N'U') IS NULL
CREATE TABLE ops.BackupRun (
    run_id uniqueidentifier NOT NULL PRIMARY KEY DEFAULT NEWID(),
    started_at datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    finished_at datetime2(3) NULL,
    backup_type char(1) NOT NULL,
    database_scope varchar(6) NOT NULL,
    requested_database sysname NULL,
    respect_schedule bit NOT NULL,
    requested_by sysname NOT NULL DEFAULT ORIGINAL_LOGIN(),
    status varchar(12) NOT NULL CHECK (status IN ('RUNNING','SUCCEEDED','PARTIAL','FAILED')),
    error_message nvarchar(2048) NULL
);
IF OBJECT_ID(N'ops.BackupItem', N'U') IS NULL
CREATE TABLE ops.BackupItem (
    item_id uniqueidentifier NOT NULL PRIMARY KEY DEFAULT NEWID(),
    run_id uniqueidentifier NOT NULL REFERENCES ops.BackupRun(run_id),
    database_name sysname NOT NULL,
    database_guid uniqueidentifier NULL,
    backup_type char(1) NOT NULL,
    started_at datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    finished_at datetime2(3) NULL,
    status varchar(12) NOT NULL CHECK (status IN ('RUNNING','SUCCEEDED','FAILED','SKIPPED')),
    reason nvarchar(2048) NULL,
    error_number int NULL,
    backup_name nvarchar(128) NOT NULL UNIQUE,
    backup_path nvarchar(1500) NULL,
    command nvarchar(max) NULL,
    backup_set_uuid uniqueidentifier NULL,
    CONSTRAINT UQ_BackupItem_RunDb UNIQUE(run_id,database_name)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ops.BackupItem') AND name=N'IX_BackupItem_Due')
CREATE INDEX IX_BackupItem_Due ON ops.BackupItem(database_name,backup_type,started_at) INCLUDE(database_guid,status);
GO
USE DBADB;
GO
INSERT cfg.SchemaVersion(version) VALUES (1);
INSERT cfg.BackupOverride(database_name,backup_type,enabled,note) VALUES(N'DBADB_IT_V1Only','D',0,N'v1 override');
INSERT ops.BackupRun(run_id,backup_type,database_scope,requested_database,respect_schedule,status,finished_at)
VALUES('11111111-1111-1111-1111-111111111111','D','USER',N'DBADB_IT_V1Only',1,'FAILED',SYSDATETIME());
INSERT ops.BackupItem(run_id,database_name,backup_type,status,reason,backup_name,finished_at)
VALUES('11111111-1111-1111-1111-111111111111',N'DBADB_IT_V1Only','D','FAILED',N'v1 failure',N'DBADB:v1-fixture',SYSDATETIME());
PRINT N'v1 fixture created.';
GO
