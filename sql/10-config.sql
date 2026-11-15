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
GO
-- v2: retry failed schedule slots. Added by ALTER so v1 databases migrate in place.
IF COL_LENGTH(N'cfg.BackupDefault',N'retry_count') IS NULL
    ALTER TABLE cfg.BackupDefault ADD retry_count int NOT NULL
        CONSTRAINT DF_BackupDefault_retry_count DEFAULT 2
        CONSTRAINT CK_BackupDefault_retry_count CHECK (retry_count BETWEEN 0 AND 10);
IF COL_LENGTH(N'cfg.BackupDefault',N'retry_interval_minutes') IS NULL
    ALTER TABLE cfg.BackupDefault ADD retry_interval_minutes int NOT NULL
        CONSTRAINT DF_BackupDefault_retry_interval DEFAULT 15
        CONSTRAINT CK_BackupDefault_retry_interval CHECK (retry_interval_minutes BETWEEN 1 AND 1440);
IF COL_LENGTH(N'cfg.BackupOverride',N'retry_count') IS NULL
    ALTER TABLE cfg.BackupOverride ADD retry_count int NULL
        CONSTRAINT CK_BackupOverride_retry_count CHECK (retry_count BETWEEN 0 AND 10);
IF COL_LENGTH(N'cfg.BackupOverride',N'retry_interval_minutes') IS NULL
    ALTER TABLE cfg.BackupOverride ADD retry_interval_minutes int NULL
        CONSTRAINT CK_BackupOverride_retry_interval CHECK (retry_interval_minutes BETWEEN 1 AND 1440);
-- v2: anchor_date fixes the weekday of multi-day intervals (2000-01-01 is a Saturday).
-- catch_up_minutes limits how late after the slot start a backup may begin; 0 = no limit.
IF COL_LENGTH(N'cfg.BackupDefault',N'anchor_date') IS NULL
    ALTER TABLE cfg.BackupDefault ADD anchor_date date NOT NULL
        CONSTRAINT DF_BackupDefault_anchor_date DEFAULT '20000101'
        CONSTRAINT CK_BackupDefault_anchor_date CHECK (anchor_date BETWEEN '20000101' AND '20991231');
IF COL_LENGTH(N'cfg.BackupDefault',N'catch_up_minutes') IS NULL
    ALTER TABLE cfg.BackupDefault ADD catch_up_minutes int NOT NULL
        CONSTRAINT DF_BackupDefault_catch_up DEFAULT 0
        CONSTRAINT CK_BackupDefault_catch_up CHECK (catch_up_minutes BETWEEN 0 AND 525600);
IF COL_LENGTH(N'cfg.BackupOverride',N'anchor_date') IS NULL
    ALTER TABLE cfg.BackupOverride ADD anchor_date date NULL
        CONSTRAINT CK_BackupOverride_anchor_date CHECK (anchor_date BETWEEN '20000101' AND '20991231');
IF COL_LENGTH(N'cfg.BackupOverride',N'catch_up_minutes') IS NULL
    ALTER TABLE cfg.BackupOverride ADD catch_up_minutes int NULL
        CONSTRAINT CK_BackupOverride_catch_up CHECK (catch_up_minutes BETWEEN 0 AND 525600);
GO
-- v3: existing policies inherit the original filename convention; overrides inherit by default.
IF COL_LENGTH(N'cfg.BackupDefault',N'filename_pattern') IS NULL
    ALTER TABLE cfg.BackupDefault ADD filename_pattern nvarchar(1000) NOT NULL
        CONSTRAINT DF_BackupDefault_filename_pattern DEFAULT N'[db_name]_[db_id]_[guid]';
IF COL_LENGTH(N'cfg.BackupOverride',N'filename_pattern') IS NULL
    ALTER TABLE cfg.BackupOverride ADD filename_pattern nvarchar(1000) NULL;
GO
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
-- v2: the session that owns a run, so attempts interrupted by KILL/stop/restart can be closed.
IF COL_LENGTH(N'ops.BackupRun',N'session_id') IS NULL
    ALTER TABLE ops.BackupRun ADD session_id int NULL;
IF COL_LENGTH(N'ops.BackupRun',N'session_login_time') IS NULL
    ALTER TABLE ops.BackupRun ADD session_login_time datetime NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ops.BackupRun') AND name=N'IX_BackupRun_Status')
CREATE INDEX IX_BackupRun_Status ON ops.BackupRun(status) INCLUDE(session_id,session_login_time);
IF OBJECT_ID(N'cfg.ConfigAudit', N'U') IS NULL
CREATE TABLE cfg.ConfigAudit (
    audit_id bigint IDENTITY NOT NULL PRIMARY KEY,
    changed_at datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    login_name sysname NOT NULL DEFAULT ORIGINAL_LOGIN(),
    table_name sysname NOT NULL,
    before_rows nvarchar(max) NULL,
    after_rows nvarchar(max) NULL
);
GO
-- Backup policies decide where sysadmin-run BACKUP commands write. Only sysadmin may change
-- them, and every change is audited. db_owner can still disable a trigger, so this is a guard
-- and audit trail, not a security boundary: never grant DBADB db_owner to non-sysadmins.
CREATE OR ALTER TRIGGER cfg.TR_BackupDefault_Guard ON cfg.BackupDefault AFTER INSERT,UPDATE,DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS(SELECT 1 FROM inserted) AND NOT EXISTS(SELECT 1 FROM deleted) RETURN;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51005,'Only sysadmin may change DBADB backup policies.',1;
    INSERT cfg.ConfigAudit(table_name,before_rows,after_rows)
    VALUES(N'cfg.BackupDefault',(SELECT * FROM deleted FOR JSON PATH),(SELECT * FROM inserted FOR JSON PATH));
END;
GO
CREATE OR ALTER TRIGGER cfg.TR_BackupOverride_Guard ON cfg.BackupOverride AFTER INSERT,UPDATE,DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS(SELECT 1 FROM inserted) AND NOT EXISTS(SELECT 1 FROM deleted) RETURN;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51005,'Only sysadmin may change DBADB backup policies.',1;
    INSERT cfg.ConfigAudit(table_name,before_rows,after_rows)
    VALUES(N'cfg.BackupOverride',(SELECT * FROM deleted FOR JSON PATH),(SELECT * FROM inserted FOR JSON PATH));
END;
GO
