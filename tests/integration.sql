-- DESTRUCTIVE TEST FIXTURE: disposable instance only. Run through tests/run.py.
:On Error exit
USE master;
GO
CREATE DATABASE DBADB_IT_Full;
CREATE DATABASE DBADB_IT_Simple;
CREATE DATABASE DBADB_IT_Offline;
CREATE DATABASE DBADB_IT_BadPath;
CREATE DATABASE DBADB_IT_NoBase;
CREATE DATABASE DBADB_IT_LS;
ALTER DATABASE DBADB_IT_Full SET RECOVERY FULL;
ALTER DATABASE DBADB_IT_Simple SET RECOVERY SIMPLE;
ALTER DATABASE DBADB_IT_NoBase SET RECOVERY FULL;
ALTER DATABASE DBADB_IT_LS SET RECOVERY FULL;
ALTER DATABASE DBADB_IT_Offline SET OFFLINE;
GO
USE DBADB;
GO
SET NOCOUNT ON;
-- install.sql ran over the v1 fixture: new columns are backfilled, v1 data and history are kept.
IF EXISTS(SELECT 1 FROM cfg.BackupDefault WHERE retry_count<>2 OR retry_interval_minutes<>15 OR anchor_date<>'20000101' OR catch_up_minutes<>0)
    OR (SELECT COUNT(*) FROM cfg.BackupDefault)<>6
    THROW 52000,'v1 -> v2 upgrade did not backfill defaults.',1;
IF NOT EXISTS(SELECT 1 FROM cfg.BackupOverride WHERE database_name=N'DBADB_IT_V1Only' AND note=N'v1 override'
    AND retry_count IS NULL AND anchor_date IS NULL AND catch_up_minutes IS NULL)
    OR NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE backup_name=N'DBADB:v1-fixture' AND status='FAILED')
    OR NOT EXISTS(SELECT 1 FROM ops.BackupRun WHERE run_id='11111111-1111-1111-1111-111111111111' AND session_id IS NULL)
    THROW 52000,'v1 -> v2 upgrade lost v1 data.',1;
IF (SELECT STRING_AGG(CONVERT(varchar(3),version),',') WITHIN GROUP (ORDER BY version) FROM cfg.SchemaVersion)<>'1,2,3'
    THROW 52000,'Schema version history wrong after upgrade.',1;
IF (SELECT COUNT(*) FROM cfg.AgentJob)<>7 THROW 52000,'Expected seven managed jobs.',1;
IF EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id WHERE j.owner_sid<>0x01)
    THROW 52000,'New jobs must be owned by sa.',1;
IF EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id WHERE j.enabled<>0)
    THROW 52000,'New jobs must be disabled.',1;
IF (SELECT start_time FROM cfg.BackupDefault WHERE database_scope='USER' AND backup_type='D')<>'02:00'
    THROW 52000,'Default user full time mismatch.',1;
IF (SELECT interval_minutes FROM cfg.BackupDefault WHERE database_scope='USER' AND backup_type='L')<>15
    THROW 52000,'Default log interval mismatch.',1;
UPDATE cfg.BackupDefault SET enabled=0,directory=N'$(BackupDirectory)';
INSERT cfg.BackupOverride(database_name,backup_type,enabled)
SELECT d.name,t.backup_type,1 FROM sys.databases d CROSS JOIN (VALUES('D'),('I'),('L')) t(backup_type)
WHERE d.name IN (N'DBADB_IT_Full',N'DBADB_IT_Simple',N'DBADB_IT_Offline',N'DBADB_IT_BadPath',N'DBADB_IT_NoBase',N'DBADB_IT_LS');
UPDATE cfg.BackupOverride SET directory=N'Z:\DBADB_nonexistent_directory' WHERE database_name=N'DBADB_IT_BadPath';
IF (SELECT exclusion_reason FROM report.EffectiveBackupPolicy WHERE database_name=N'tempdb' AND backup_type='D')<>N'TEMPDB_NOT_SUPPORTED'
    THROW 52000,'tempdb protection missing.',1;
IF EXISTS(SELECT 1 FROM report.EffectiveBackupPolicy WHERE database_name IN(N'master',N'model',N'msdb') AND backup_type IN('I','L')
    AND exclusion_reason<>N'SYSTEM_DATABASE_FULL_ONLY') THROW 52000,'System database guard missing.',1;
CREATE DATABASE DBADB_IT_New;
IF NOT EXISTS(SELECT 1 FROM report.EffectiveBackupPolicy WHERE database_name=N'DBADB_IT_New' AND backup_type='D'
    AND enabled=0 AND directory=N'$(BackupDirectory)') THROW 52000,'New database did not inherit policy.',1;
DECLARE @excluded_run uniqueidentifier;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_New',@RespectSchedule=1,@RunId=@excluded_run OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@excluded_run AND status='SKIPPED' AND reason=N'POLICY_DISABLED')
    THROW 52000,'Scheduled disabled policy exclusion not recorded.',1;
DELETE ops.BackupItem WHERE run_id=@excluded_run;
DELETE ops.BackupRun WHERE run_id=@excluded_run;
INSERT cfg.BackupOverride(database_name,backup_type,enabled,directory) VALUES(N'DBADB_IT_New','I',1,N'');
EXEC ops.usp_Backup @BackupType='I',@DatabaseName=N'DBADB_IT_New',@RespectSchedule=1,@RunId=@excluded_run OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@excluded_run AND status='SKIPPED' AND reason=N'BACKUP_DIRECTORY_NOT_CONFIGURED')
    THROW 52000,'Scheduled missing path exclusion not recorded.',1;
DELETE ops.BackupItem WHERE run_id=@excluded_run;
DELETE ops.BackupRun WHERE run_id=@excluded_run;
DELETE cfg.BackupOverride WHERE database_name=N'DBADB_IT_New' AND backup_type='I';
IF cfg.ufn_ScheduleSlotAt('20261114 02:15','20000101','02:00',1440)<>'20261114 02:00'
    OR cfg.ufn_ScheduleSlotAt('20261114 01:59','20000101','02:00',1440)<>'20261113 02:00'
    OR cfg.ufn_ScheduleSlotAt('20261114 02:14','20000101','00:00',15)<>'20261114 02:00'
    -- Fractional seconds must not round into the next slot.
    OR cfg.ufn_ScheduleSlotAt('20261114 01:59:59.700','20000101','02:00',1440)<>'20261113 02:00'
    -- Weekly on Sunday (2000-01-02 is a Sunday; 2026-11-14 is a Saturday).
    OR cfg.ufn_ScheduleSlotAt('20261114 10:00','20000102','02:00',10080)<>'20261108 02:00'
    OR cfg.ufn_ScheduleSlotAt('20261114 10:00','20000101','02:00',10080)<>'20261114 02:00'
    -- An anchor in the future still yields a slot at or before now.
    OR cfg.ufn_ScheduleSlotAt('20261114 10:00','20270101','02:00',1440)<>'20261114 02:00'
    -- v1 three-argument signature still works for procedures running during an upgrade.
    OR cfg.ufn_ScheduleSlot('20261114 02:15','02:00',1440)<>'20261114 02:00'
    THROW 52000,'Schedule calculation failed.',1;
DECLARE @cmd nvarchar(max),@path nvarchar(1500),@reason nvarchar(2048),@item uniqueidentifier=NEWID();
EXEC ops.usp_PlanBackup N'DBADB_IT_NoBase','I',@item,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT;
IF @reason<>N'DIFFERENTIAL_BASE_NOT_AVAILABLE_TAKE_REGULAR_FULL_BACKUP' OR @reason IS NULL
    THROW 52000,'Missing differential base not detected.',1;
-- Filename templates use the same planner for preview and execution.
IF EXISTS(SELECT 1 FROM cfg.BackupDefault WHERE filename_pattern<>N'[db_name]_[db_id]_[guid]')
    OR EXISTS(SELECT 1 FROM cfg.BackupOverride WHERE filename_pattern IS NOT NULL)
    THROW 52000,'Filename pattern upgrade defaults incorrect.',1;
UPDATE cfg.BackupDefault SET filename_pattern=N'[yyyymmddHHmi]_[db_id]_[db_name]_[guid]_[guid]' WHERE database_scope='USER' AND backup_type='D';
DECLARE @fixed uniqueidentifier='01234567-89ab-cdef-0123-456789abcdef',@when datetime2(3)='2026-11-14T01:59:59.700';
EXEC ops.usp_PlanBackup N'DBADB_IT_Full','D',@fixed,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT,@when;
IF @reason IS NOT NULL OR @path NOT LIKE N'%202611140159%0123456789abcdef0123456789abcdef_0123456789abcdef0123456789abcdef.bak'
    THROW 52000,'Filename template expansion or minute boundary failed.',1;
UPDATE cfg.BackupOverride SET filename_pattern=N'custom_[guid]' WHERE database_name=N'DBADB_IT_Full' AND backup_type='D';
IF (SELECT filename_pattern FROM report.EffectiveBackupPolicy WHERE database_name=N'DBADB_IT_Full' AND backup_type='D')<>N'custom_[guid]'
    THROW 52000,'Filename override failed.',1;
UPDATE cfg.BackupOverride SET directory=N'\\server\share\backups' WHERE database_name=N'DBADB_IT_Full' AND backup_type='D';
EXEC ops.usp_PlanBackup N'DBADB_IT_Full','D',@fixed,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT,@when;
IF @reason IS NOT NULL OR @path NOT LIKE N'\\server\share\backups\custom[_]%'
    THROW 52000,'UNC filename planning failed.',1;
UPDATE cfg.BackupOverride SET directory=N'C:\'+REPLICATE(N'x',240) WHERE database_name=N'DBADB_IT_Full' AND backup_type='D';
EXEC ops.usp_PlanBackup N'DBADB_IT_Full','D',@fixed,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT,@when;
IF @reason<>N'BACKUP_PATH_TOO_LONG_MAX_259' OR @cmd IS NOT NULL
    THROW 52000,'Long path was not excluded.',1;
UPDATE cfg.BackupOverride SET directory=NULL WHERE database_name=N'DBADB_IT_Full' AND backup_type='D';
DECLARE @bad TABLE(pattern nvarchar(1000),reason nvarchar(100));
INSERT @bad VALUES(N'',N'EMPTY_FILENAME_PATTERN'),(N'plain',N'FILENAME_PATTERN_REQUIRES_GUID'),
    (N'[guid]_[unknown]',N'UNKNOWN_FILENAME_PATTERN_TOKEN'),(N'[guid]/bad',N'INVALID_FILENAME_PATTERN'),
    (N'CON.[guid]',N'INVALID_BACKUP_FILENAME'),(REPLICATE(N'x',240)+N'[guid]',N'INVALID_BACKUP_FILENAME');
DECLARE @badpattern nvarchar(1000),@expected nvarchar(100);
DECLARE bad_patterns CURSOR LOCAL FAST_FORWARD FOR SELECT pattern,reason FROM @bad;
OPEN bad_patterns; FETCH NEXT FROM bad_patterns INTO @badpattern,@expected;
WHILE @@FETCH_STATUS=0
BEGIN
    UPDATE cfg.BackupOverride SET filename_pattern=@badpattern WHERE database_name=N'DBADB_IT_Full' AND backup_type='D';
    EXEC ops.usp_PlanBackup N'DBADB_IT_Full','D',@fixed,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT,@when;
    IF @reason IS NULL OR @reason<>@expected OR @cmd IS NOT NULL THROW 52000,'Invalid pattern was not excluded.',1;
    FETCH NEXT FROM bad_patterns INTO @badpattern,@expected;
END;
CLOSE bad_patterns; DEALLOCATE bad_patterns;
UPDATE cfg.BackupOverride SET filename_pattern=NULL WHERE database_name=N'DBADB_IT_Full' AND backup_type='D';
UPDATE cfg.BackupDefault SET filename_pattern=N'[db_name]_[db_id]_[guid]' WHERE database_scope='USER' AND backup_type='D';
DECLARE @r uniqueidentifier;
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_Simple',@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'SIMPLE_RECOVERY_NO_LOG_BACKUP')
    THROW 52000,'SIMPLE guard missing.',1;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Offline',@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'DATABASE_NOT_ONLINE')
    THROW 52000,'Offline guard missing.',1;
-- Scheduled exclusions are recorded, with no duplicate within the same slot.
DECLARE @items_before int=(SELECT COUNT(*) FROM ops.BackupItem);
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Offline',@RespectSchedule=1,@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'DATABASE_NOT_ONLINE')
    THROW 52000,'Scheduled offline exclusion not recorded.',1;
DECLARE @offline_count int=(SELECT COUNT(*) FROM ops.BackupItem WHERE database_name=N'DBADB_IT_Offline' AND backup_type='D');
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Offline',@RespectSchedule=1,@RunId=@r OUTPUT;
IF @r IS NOT NULL OR @offline_count<>(SELECT COUNT(*) FROM ops.BackupItem WHERE database_name=N'DBADB_IT_Offline' AND backup_type='D')
    THROW 52000,'Offline exclusion retried before retry interval.',1;
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_Simple',@RespectSchedule=1,@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'SIMPLE_RECOVERY_NO_LOG_BACKUP')
    THROW 52000,'Scheduled SIMPLE exclusion not recorded.',1;
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_Simple',@RespectSchedule=1,@RunId=@r OUTPUT;
IF @r IS NOT NULL THROW 52000,'Scheduled SIMPLE exclusion duplicated within slot.',1;
-- Interrupted attempts are closed as FAILED: a session that ended (KILL, Agent stop, restart), and this
-- session's own earlier run aborted by a cancel/timeout, whose leaked (re-entrant) lock is released.
DECLARE @dead uniqueidentifier=NEWID(),@live uniqueidentifier=NEWID(),
    @leaked nvarchar(255)=N'DBADB:Backup:'+CONVERT(nvarchar(10),DB_ID(N'DBADB_IT_New'));
INSERT ops.BackupRun(run_id,backup_type,database_scope,respect_schedule,status,session_id,session_login_time)
VALUES(@dead,'D','USER',1,'RUNNING',32700,'20000101');
INSERT ops.BackupRun(run_id,backup_type,database_scope,respect_schedule,status,session_id,session_login_time)
SELECT @live,'D','USER',1,'RUNNING',@@SPID,login_time FROM sys.dm_exec_sessions WHERE session_id=@@SPID;
INSERT ops.BackupItem(run_id,database_name,backup_type,status,backup_name)
VALUES(@dead,N'DBADB_IT_Orphan','D','RUNNING',N'DBADB:it-dead'),(@live,N'DBADB_IT_New','D','RUNNING',N'DBADB:it-live');
EXEC sys.sp_getapplock @Resource=@leaked,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
EXEC sys.sp_getapplock @Resource=@leaked,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Offline',@RespectSchedule=1;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE backup_name=N'DBADB:it-dead' AND status='FAILED'
        AND reason=N'ATTEMPT_INTERRUPTED_SESSION_ENDED' AND finished_at IS NOT NULL)
    OR NOT EXISTS(SELECT 1 FROM ops.BackupRun WHERE run_id=@dead AND status='FAILED')
    OR NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE backup_name=N'DBADB:it-live' AND status='FAILED'
        AND reason=N'ATTEMPT_ABORTED_IN_THIS_SESSION')
    OR APPLOCK_MODE(N'public',@leaked,N'Session')<>N'NoLock'
    THROW 52000,'Interrupted attempt reconciliation failed.',1;
DELETE ops.BackupItem WHERE backup_name IN (N'DBADB:it-dead',N'DBADB:it-live');
-- A failure recorded before v2 (no session) settles its slot as in v1: no daytime retry after upgrading.
DECLARE @v1run uniqueidentifier=NEWID(),@v1slot datetime2(0)=DATEADD(minute,-30,SYSDATETIME());
INSERT ops.BackupRun(run_id,backup_type,database_scope,respect_schedule,status) VALUES(@v1run,'I','USER',1,'FAILED');
INSERT ops.BackupItem(run_id,database_name,database_guid,backup_type,status,backup_name,started_at,finished_at)
SELECT @v1run,N'DBADB_IT_New',database_guid,'I','FAILED',N'DBADB:it-v1',DATEADD(minute,-20,SYSDATETIME()),DATEADD(minute,-20,SYSDATETIME())
FROM sys.database_recovery_status WHERE database_id=DB_ID(N'DBADB_IT_New');
IF EXISTS(SELECT 1 FROM ops.ufn_SlotDue(N'DBADB_IT_New',(SELECT database_guid FROM sys.database_recovery_status WHERE database_id=DB_ID(N'DBADB_IT_New')),
        'I',@v1slot,2,15,0,SYSDATETIME(),NULL) WHERE is_due=1)
    THROW 52000,'Pre-v2 failure became retryable after upgrade.',1;
DELETE ops.BackupItem WHERE run_id=@v1run;
DELETE ops.BackupRun WHERE run_id=@v1run;
DELETE ops.BackupRun WHERE run_id IN (@dead,@live);
EXEC ops.usp_PreviewBackup @DatabaseName=N'DBADB_IT_Full';
UPDATE cfg.BackupDefault SET enabled=1 WHERE database_scope='SYSTEM' AND backup_type='D';
EXEC ops.usp_Backup @DatabaseScope='SYSTEM',@RunId=@r OUTPUT;
IF (SELECT COUNT(*) FROM ops.BackupItem WHERE run_id=@r AND database_name IN (N'master',N'model',N'msdb') AND status='SUCCEEDED')<>3
    THROW 52000,'System database full backup failed.',1;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND database_name=N'tempdb' AND status='SKIPPED')
    THROW 52000,'System run did not record tempdb exclusion.',1;
-- Even explicitly granted EXECUTE cannot bypass the server-level safety gate.
CREATE USER DBADB_IT_Limited WITHOUT LOGIN;
GRANT EXECUTE ON OBJECT::ops.usp_Backup TO DBADB_IT_Limited;
DECLARE @denied bit=0;
EXECUTE AS USER=N'DBADB_IT_Limited';
BEGIN TRY EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Full'; END TRY
BEGIN CATCH IF ERROR_NUMBER()=51000 SET @denied=1; END CATCH;
REVERT;
IF @denied=0 THROW 52000,'Incomplete metadata privilege gate failed.',1;
GO
USE DBADB_IT_Full;
CREATE TABLE dbo.RestoreProof(id int NOT NULL PRIMARY KEY,payload varchar(1000));
INSERT dbo.RestoreProof VALUES(1,'full');
-- A second filegroup, partitioned base and nonclustered index expose join-multiplication errors.
ALTER DATABASE DBADB_IT_Full ADD FILEGROUP EXTRA;
ALTER DATABASE DBADB_IT_Full ADD FILE(NAME=N'DBADB_IT_Extra',FILENAME=N'$(BackupDirectory)\DBADB_IT_Extra.ndf',SIZE=8MB) TO FILEGROUP EXTRA;
CREATE PARTITION FUNCTION IT_Range(int) AS RANGE RIGHT FOR VALUES(100);
CREATE PARTITION SCHEME IT_Scheme AS PARTITION IT_Range TO ([PRIMARY],EXTRA);
CREATE TABLE dbo.Partitioned(id int NOT NULL,payload varchar(1000)) ON IT_Scheme(id);
CREATE CLUSTERED INDEX CX_Partitioned ON dbo.Partitioned(id) ON IT_Scheme(id);
CREATE INDEX IX_Partitioned ON dbo.Partitioned(payload) ON IT_Scheme(id);
INSERT dbo.Partitioned SELECT TOP(250) ROW_NUMBER() OVER(ORDER BY (SELECT NULL)),REPLICATE('x',500) FROM sys.all_objects;
GO
USE DBADB;
GO
DECLARE @r uniqueidentifier,@full nvarchar(1500),@diff nvarchar(1500),@log nvarchar(1500),@sql nvarchar(max);
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Full',@RunId=@r OUTPUT;
SELECT @full=backup_path FROM ops.BackupItem WHERE run_id=@r;
INSERT DBADB_IT_Full.dbo.RestoreProof VALUES(2,'diff');
EXEC ops.usp_Backup @BackupType='I',@DatabaseName=N'DBADB_IT_Full',@RunId=@r OUTPUT;
SELECT @diff=backup_path FROM ops.BackupItem WHERE run_id=@r;
INSERT DBADB_IT_Full.dbo.RestoreProof VALUES(3,'log');
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_Full',@RunId=@r OUTPUT;
SELECT @log=backup_path FROM ops.BackupItem WHERE run_id=@r;
RESTORE VERIFYONLY FROM DISK=@full WITH CHECKSUM;
RESTORE VERIFYONLY FROM DISK=@diff WITH CHECKSUM;
RESTORE VERIFYONLY FROM DISK=@log WITH CHECKSUM;
RESTORE DATABASE DBADB_IT_Restore FROM DISK=@full WITH NORECOVERY,
    MOVE N'DBADB_IT_Full' TO N'$(BackupDirectory)\DBADB_IT_Restore.mdf',
    MOVE N'DBADB_IT_Full_log' TO N'$(BackupDirectory)\DBADB_IT_Restore_log.ldf',
    MOVE N'DBADB_IT_Extra' TO N'$(BackupDirectory)\DBADB_IT_Restore_extra.ndf';
RESTORE DATABASE DBADB_IT_Restore FROM DISK=@diff WITH NORECOVERY;
RESTORE LOG DBADB_IT_Restore FROM DISK=@log WITH RECOVERY;
IF (SELECT COUNT(*) FROM DBADB_IT_Restore.dbo.RestoreProof)<>3 THROW 52000,'Restored data mismatch.',1;
-- A failed DB must not stop backups of other DBs; Agent must still receive failure.
DECLARE @failed bit=0;
BEGIN TRY EXEC ops.usp_Backup @RunId=@r OUTPUT; END TRY
BEGIN CATCH IF ERROR_NUMBER()<>51002 THROW; SET @failed=1; END CATCH;
-- SQL Server does not copy OUTPUT parameters back to callers when a procedure throws.
SELECT TOP(1) @r=run_id FROM ops.BackupRun WHERE requested_database IS NULL ORDER BY started_at DESC;
IF @failed=0 OR NOT EXISTS(SELECT 1 FROM ops.BackupRun WHERE run_id=@r AND status='PARTIAL')
    THROW 52000,'Partial failure not propagated.',1;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND database_name=N'DBADB_IT_BadPath' AND status='FAILED')
    OR NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND database_name=N'DBADB_IT_Full' AND status='SUCCEEDED')
    THROW 52000,'Per database isolation failed.',1;
IF NOT EXISTS(SELECT 1 FROM report.BackupHealth WHERE database_name=N'DBADB_IT_BadPath' AND backup_type='D' AND health_status='FAILED')
    THROW 52000,'Backup health did not expose failure.',1;
-- Already-attempted slot must not run another backup or create no-op history.
DECLARE @count int=(SELECT COUNT(*) FROM ops.BackupItem WHERE database_name=N'DBADB_IT_Full' AND backup_type='D');
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Full',@RespectSchedule=1,@RunId=@r OUTPUT;
IF @r IS NOT NULL OR @count<>(SELECT COUNT(*) FROM ops.BackupItem WHERE database_name=N'DBADB_IT_Full' AND backup_type='D')
    THROW 52000,'Schedule attempted twice.',1;
-- Scheduled failures retry inside the same slot after retry_interval_minutes (measured from finish),
-- at most retry_count extra times. Manual failures neither consume retries nor delay them.
DECLARE @slot_start time(0)=CONVERT(time(0),DATEADD(minute,DATEDIFF(minute,0,DATEADD(minute,-60,SYSDATETIME())),0));
UPDATE cfg.BackupOverride SET start_time=@slot_start,interval_minutes=1440,retry_count=1,retry_interval_minutes=15
    WHERE database_name=N'DBADB_IT_BadPath' AND backup_type='D';
SET @failed=0;
BEGIN TRY EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_BadPath',@RespectSchedule=1; END TRY
BEGIN CATCH IF ERROR_NUMBER()<>51002 THROW; SET @failed=1; END CATCH;
IF @failed=0 THROW 52000,'A recent manual failure blocked the scheduled attempt.',1;
-- Long attempt that started long ago but finished recently: still waiting.
UPDATE i SET started_at=DATEADD(minute,-40,SYSDATETIME()),finished_at=DATEADD(minute,-5,SYSDATETIME())
FROM ops.BackupItem i JOIN ops.BackupRun r ON r.run_id=i.run_id
WHERE i.database_name=N'DBADB_IT_BadPath' AND i.backup_type='D' AND i.status='FAILED' AND r.respect_schedule=1;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_BadPath',@RespectSchedule=1,@RunId=@r OUTPUT;
IF @r IS NOT NULL THROW 52000,'Failed slot retried before the retry interval elapsed after finish.',1;
UPDATE i SET started_at=DATEADD(minute,-25,SYSDATETIME()),finished_at=DATEADD(minute,-20,SYSDATETIME())
FROM ops.BackupItem i JOIN ops.BackupRun r ON r.run_id=i.run_id
WHERE i.database_name=N'DBADB_IT_BadPath' AND i.backup_type='D' AND i.status='FAILED' AND r.respect_schedule=1;
SET @failed=0;
BEGIN TRY EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_BadPath',@RespectSchedule=1; END TRY
BEGIN CATCH IF ERROR_NUMBER()<>51002 THROW; SET @failed=1; END CATCH;
IF @failed=0 OR (SELECT COUNT(*) FROM ops.BackupItem i JOIN ops.BackupRun r ON r.run_id=i.run_id
    WHERE i.database_name=N'DBADB_IT_BadPath' AND i.backup_type='D' AND i.status='FAILED' AND r.respect_schedule=1)<>2
    THROW 52000,'Failed slot was not retried after the retry interval.',1;
UPDATE i SET started_at=DATEADD(minute,-25,SYSDATETIME()),finished_at=DATEADD(minute,-20,SYSDATETIME())
FROM ops.BackupItem i JOIN ops.BackupRun r ON r.run_id=i.run_id
WHERE i.database_name=N'DBADB_IT_BadPath' AND i.backup_type='D' AND i.status='FAILED' AND r.respect_schedule=1;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_BadPath',@RespectSchedule=1,@RunId=@r OUTPUT;
IF @r IS NOT NULL THROW 52000,'Failed slot retried beyond retry_count.',1;
-- Enabled policies that cannot back up are UNPROTECTED; an explicit enabled=0 makes them EXCLUDED.
IF NOT EXISTS(SELECT 1 FROM report.BackupHealth WHERE database_name=N'DBADB_IT_Offline' AND backup_type='D' AND health_status='UNPROTECTED')
    THROW 52000,'Offline enabled policy not reported as UNPROTECTED.',1;
INSERT cfg.BackupOverride(database_name,backup_type,enabled,directory) VALUES(N'DBADB_IT_New','D',1,N'');
IF NOT EXISTS(SELECT 1 FROM report.BackupHealth WHERE database_name=N'DBADB_IT_New' AND backup_type='D' AND health_status='UNPROTECTED'
    AND exclusion_reason=N'BACKUP_DIRECTORY_NOT_CONFIGURED') THROW 52000,'Missing directory not reported as UNPROTECTED.',1;
DELETE cfg.BackupOverride WHERE database_name=N'DBADB_IT_New';
UPDATE cfg.BackupOverride SET enabled=0 WHERE database_name=N'DBADB_IT_Offline' AND backup_type='D';
IF NOT EXISTS(SELECT 1 FROM report.BackupHealth WHERE database_name=N'DBADB_IT_Offline' AND backup_type='D' AND health_status='EXCLUDED')
    THROW 52000,'Explicitly disabled policy not reported as EXCLUDED.',1;
-- The health check keeps failing while problems remain, even after backup jobs return to success.
DECLARE @health_error int=NULL,@health_message nvarchar(2048);
BEGIN TRY EXEC ops.usp_CheckBackupHealth; END TRY
BEGIN CATCH SELECT @health_error=ERROR_NUMBER(),@health_message=ERROR_MESSAGE(); END CATCH;
IF ISNULL(@health_error,0)<>51004 OR @health_message NOT LIKE N'%FAILED=%' OR @health_message NOT LIKE N'%UNPROTECTED=%'
    THROW 52000,'Health check did not report failures.',1;
-- catch_up_minutes stops a slot from starting too long after its start (e.g. on enabling a job at noon).
SET @slot_start=CONVERT(time(0),DATEADD(minute,DATEDIFF(minute,0,DATEADD(minute,-60,SYSDATETIME())),0));
INSERT cfg.BackupOverride(database_name,backup_type,enabled,start_time,interval_minutes,catch_up_minutes)
VALUES(N'DBADB_IT_New','D',1,@slot_start,1440,30);
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_New',@RespectSchedule=1,@RunId=@r OUTPUT;
IF @r IS NOT NULL THROW 52000,'Backup started outside the catch-up window.',1;
UPDATE cfg.BackupOverride SET catch_up_minutes=90 WHERE database_name=N'DBADB_IT_New' AND backup_type='D';
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_New',@RespectSchedule=1,@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SUCCEEDED')
    THROW 52000,'Backup did not start inside the catch-up window.',1;
DELETE cfg.BackupOverride WHERE database_name=N'DBADB_IT_New';
-- Policy changes are sysadmin-only and audited.
IF NOT EXISTS(SELECT 1 FROM cfg.ConfigAudit WHERE table_name=N'cfg.BackupOverride' AND login_name=ORIGINAL_LOGIN()
    AND before_rows LIKE N'%DBADB_IT_New%' AND after_rows IS NULL)
    THROW 52000,'Policy change was not audited.',1;
GRANT SELECT,UPDATE ON OBJECT::cfg.BackupDefault TO DBADB_IT_Limited;
DECLARE @guard int=NULL,@guard_message nvarchar(2048);
EXECUTE AS USER=N'DBADB_IT_Limited';
BEGIN TRY UPDATE cfg.BackupDefault SET directory=N'\\attacker\share' WHERE database_scope='USER'; END TRY
BEGIN CATCH SELECT @guard=ERROR_NUMBER(),@guard_message=ERROR_MESSAGE(); END CATCH;
REVERT;
IF ISNULL(@guard,0)<>51005 OR EXISTS(SELECT 1 FROM cfg.BackupDefault WHERE directory LIKE N'\\attacker%')
BEGIN
    SET @guard_message=N'Non-sysadmin policy change was not blocked: '+ISNULL(CONVERT(nvarchar(10),@guard)+N' '+@guard_message,N'no error');
    THROW 52000,@guard_message,1;
END;
REVOKE SELECT,UPDATE ON OBJECT::cfg.BackupDefault FROM DBADB_IT_Limited;
-- Operational purge keeps successes/failures and refuses short windows.
BEGIN TRY EXEC ops.usp_PurgeOperationalHistory @KeepDays=29; THROW 52000,'Short purge window accepted.',1; END TRY
BEGIN CATCH IF ERROR_NUMBER()<>51000 THROW; END CATCH;
UPDATE ops.BackupItem SET started_at=DATEADD(day,-100,started_at) WHERE database_name=N'DBADB_IT_Simple';
DECLARE @kept int=(SELECT COUNT(*) FROM ops.BackupItem WHERE status IN ('SUCCEEDED','FAILED'));
EXEC ops.usp_PurgeOperationalHistory @KeepDays=90;
IF EXISTS(SELECT 1 FROM ops.BackupItem WHERE database_name=N'DBADB_IT_Simple' AND status='SKIPPED')
    OR NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE database_name=N'DBADB_IT_Simple' AND status='SUCCEEDED')
    OR @kept<>(SELECT COUNT(*) FROM ops.BackupItem WHERE status IN ('SUCCEEDED','FAILED'))
    THROW 52000,'Operational purge removed the wrong rows.',1;
-- Manual and separately owned Agent backups must remain unattributed.
BACKUP DATABASE DBADB_IT_Full TO DISK=N'$(BackupDirectory)\DBADB_IT_manual.bak' WITH COPY_ONLY,INIT,CHECKSUM;
BACKUP DATABASE DBADB_IT_Full TO DISK=N'$(BackupDirectory)\DBADB_IT_stripe1.bak',
    DISK=N'$(BackupDirectory)\DBADB_IT_stripe2.bak' WITH COPY_ONLY,INIT,CHECKSUM,NAME=N'DBADB_IT_striped';
IF (SELECT COUNT(*) FROM report.BackupHistory WHERE backup_name=N'DBADB_IT_striped')<>1
    OR (SELECT COUNT(*) FROM report.BackupMedia m JOIN report.BackupHistory h ON h.backup_set_uuid=m.backup_set_uuid
        WHERE h.backup_name=N'DBADB_IT_striped')<>2
    THROW 52000,'Striped backup set/media separation failed.',1;
DECLARE @job uniqueidentifier,@owner sysname=ORIGINAL_LOGIN(),@deadline datetime2=DATEADD(second,45,SYSDATETIME());
EXEC msdb.dbo.sp_add_job @job_name=N'DBADB_IT_external',@enabled=1,@owner_login_name=@owner,@job_id=@job OUTPUT;
SET @sql=N'BACKUP DATABASE DBADB_IT_Full TO DISK=N''$(BackupDirectory)\DBADB_IT_agent.bak'' WITH COPY_ONLY,INIT,CHECKSUM;';
EXEC msdb.dbo.sp_add_jobstep @job_id=@job,@step_name=N'External backup',@command=@sql,@database_name=N'master';
EXEC msdb.dbo.sp_add_jobserver @job_id=@job;
EXEC msdb.dbo.sp_start_job @job_id=@job;
WHILE NOT EXISTS(SELECT 1 FROM msdb.dbo.sysjobhistory WHERE job_id=@job AND step_id=0 AND run_status=1)
BEGIN
    IF SYSDATETIME()>@deadline THROW 52000,'External Agent backup did not complete.',1;
    WAITFOR DELAY '00:00:01';
END;
IF (SELECT COUNT(*) FROM report.BackupHistory h JOIN report.BackupMedia m ON m.backup_set_uuid=h.backup_set_uuid
    WHERE m.physical_device_name LIKE N'%DBADB_IT[_]manual.bak' OR m.physical_device_name LIKE N'%DBADB_IT[_]agent.bak')<>2
    THROW 52000,'Live history missing external backups.',1;
IF EXISTS(SELECT 1 FROM report.BackupHistory h JOIN report.BackupMedia m ON m.backup_set_uuid=h.backup_set_uuid
    WHERE (m.physical_device_name LIKE N'%DBADB_IT[_]manual.bak' OR m.physical_device_name LIKE N'%DBADB_IT[_]agent.bak')
    AND execution_source<>'UNATTRIBUTED') THROW 52000,'External backup was misattributed.',1;
EXEC collect.usp_BackupHistory;
DECLARE @history int=(SELECT COUNT(*) FROM collect.BackupHistory);
EXEC collect.usp_BackupHistory;
IF @history<>(SELECT COUNT(*) FROM collect.BackupHistory) THROW 52000,'History collection is not idempotent.',1;
DECLARE @before int=(SELECT COUNT(*) FROM report.BackupHistory WHERE database_name=N'DBADB_IT_Full');
EXEC msdb.dbo.sp_delete_database_backuphistory @database_name=N'DBADB_IT_Full';
IF @before<>(SELECT COUNT(*) FROM report.BackupHistory WHERE database_name=N'DBADB_IT_Full')
    THROW 52000,'Archived history lost after msdb cleanup.',1;
IF EXISTS(SELECT backup_set_uuid FROM report.BackupHistory GROUP BY backup_set_uuid HAVING COUNT(*)>1)
    THROW 52000,'Duplicate unified backup history.',1;
IF NOT EXISTS(SELECT 1 FROM report.BackupHistory WHERE database_name=N'DBADB_IT_Full' AND execution_source='PROJECT' AND run_id IS NOT NULL)
    THROW 52000,'Project history linkage missing.',1;
EXEC collect.usp_Capacity @DatabaseName=N'DBADB_IT_Full';
IF (SELECT COUNT(*) FROM report.FilegroupSpace WHERE database_name=N'DBADB_IT_Full')<>2
    THROW 52000,'Filegroup aggregation failed.',1;
IF NOT EXISTS(SELECT 1 FROM report.TableSpace WHERE database_name=N'DBADB_IT_Full' AND table_name=N'Partitioned'
    AND row_count=250 AND used_pages=data_pages+index_pages AND reserved_pages>=used_pages)
    THROW 52000,'Partitioned table aggregation failed.',1;
DECLARE @expected bigint;
SELECT @expected=SUM(used_page_count) FROM DBADB_IT_Full.sys.dm_db_partition_stats WHERE object_id=OBJECT_ID(N'DBADB_IT_Full.dbo.Partitioned');
IF @expected<>(SELECT used_pages FROM report.TableSpace WHERE database_name=N'DBADB_IT_Full' AND table_name=N'Partitioned')
    THROW 52000,'Table space multiplied across partitions or indexes.',1;
ALTER DATABASE DBADB_IT_Full SET OFFLINE WITH ROLLBACK IMMEDIATE;
-- Unsupported states are skipped without failing the job; the last good snapshot stays.
EXEC collect.usp_Capacity @DatabaseName=N'DBADB_IT_Full';
IF NOT EXISTS(SELECT 1 FROM report.TableSpace WHERE database_name=N'DBADB_IT_Full' AND collection_status='SKIPPED'
        AND collected_at IS NOT NULL AND error_message IS NOT NULL)
    OR NOT EXISTS(SELECT 1 FROM collect.CollectionRun WHERE collection_id=(SELECT MAX(collection_id) FROM collect.CollectionRun) AND status='SUCCEEDED')
    THROW 52000,'Last good capacity snapshot/skip reason not preserved.',1;
ALTER DATABASE DBADB_IT_Full SET ONLINE;
GO
-- Real native metadata; all native LS jobs remain disabled and never run in this test.
DECLARE @job uniqueidentifier,@primary uniqueidentifier;
EXEC master.dbo.sp_add_log_shipping_primary_database @database=N'DBADB_IT_LS',
    @backup_directory=N'$(BackupDirectory)',@backup_share=N'\\DBADB_IT_host\share',
    @backup_job_name=N'DBADB_IT_LS_backup',@backup_retention_period=1440,@backup_threshold=60,
    @history_retention_period=1440,@backup_job_id=@job OUTPUT,@primary_id=@primary OUTPUT,@monitor_server_security_mode=1;
DECLARE @r uniqueidentifier,@cmd nvarchar(max),@path nvarchar(1500),@reason nvarchar(2048),@item uniqueidentifier=NEWID();
-- Explicit enabled=1 overrides cannot bypass the safety rule; manual and scheduled calls are guarded.
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_LS',@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'LOG_SHIPPING_PRIMARY_OWNS_LOG_BACKUPS' AND command IS NULL)
    THROW 52000,'Log shipping primary safety failed.',1;
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_LS',@RespectSchedule=1,@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'LOG_SHIPPING_PRIMARY_OWNS_LOG_BACKUPS' AND command IS NULL)
    THROW 52000,'Scheduled log shipping exclusion not recorded.',1;
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_LS',@RespectSchedule=1,@RunId=@r OUTPUT;
IF @r IS NOT NULL THROW 52000,'Scheduled log shipping exclusion duplicated within slot.',1;
EXEC ops.usp_PlanBackup N'DBADB_IT_LS','D',@item,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT;
IF @cmd NOT LIKE N'%COPY_ONLY%' OR @reason IS NOT NULL THROW 52000,'LS full backup must be copy-only.',1;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_LS';
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE job_id=@job AND enabled<>0)
    THROW 52000,'DBADB changed a native LS job.',1;
BEGIN TRY
    EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'DBADB_IT_LS';
    THROW 52000,'Disabled native LS job should be rejected.',1;
END TRY
BEGIN CATCH IF ERROR_NUMBER()<>51000 THROW; END CATCH;
-- Secondary registration on this local test instance, using native setup procedures.
DECLARE @copy uniqueidentifier,@restore uniqueidentifier,@secondary uniqueidentifier;
EXEC master.dbo.sp_add_log_shipping_secondary_primary @primary_server=N'DBADB_IT_remote',@primary_database=N'DBADB_IT_Source',
    @backup_source_directory=N'\\DBADB_IT_host\share',@backup_destination_directory=N'$(BackupDirectory)',
    @copy_job_name=N'DBADB_IT_LS_copy',@restore_job_name=N'DBADB_IT_LS_restore',@file_retention_period=1440,
    @copy_job_id=@copy OUTPUT,@restore_job_id=@restore OUTPUT,@secondary_id=@secondary OUTPUT,@monitor_server_security_mode=1;
EXEC master.dbo.sp_add_log_shipping_secondary_database @secondary_database=N'DBADB_IT_NoBase',
    @primary_server=N'DBADB_IT_remote',@primary_database=N'DBADB_IT_Source',@restore_delay=0,@restore_mode=0,
    @restore_threshold=45,@history_retention_period=1440;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_NoBase',@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'LOG_SHIPPING_SECONDARY')
    THROW 52000,'Log shipping secondary safety failed.',1;
IF (SELECT COUNT(*) FROM report.LogShippingStatus)<>2 THROW 52000,'Local log shipping discovery failed.',1;
SELECT * FROM report.LogShippingStatus;
SELECT * FROM report.LogShippingJobs;
SELECT * FROM report.LogShippingErrors;
SELECT * FROM report.LogShippingLogBackups;
SELECT * FROM report.ProjectSchedules;
SELECT * FROM report.BackupHealth;
SELECT * FROM report.RetentionCandidates;
SELECT * FROM report.ActiveRequests;
SELECT * FROM report.DiskSpace;
-- State markers verified again after reinstall + upgrade.
UPDATE cfg.BackupDefault SET retention_days=31 WHERE database_scope='USER' AND backup_type='D';
UPDATE cfg.BackupOverride SET note=N'preserve on upgrade' WHERE database_name=N'DBADB_IT_LS';
DECLARE @managed uniqueidentifier=(SELECT job_id FROM cfg.AgentJob WHERE job_key='HISTORY');
EXEC msdb.dbo.sp_update_job @job_id=@managed,@enabled=1;
DECLARE @schedule int=(SELECT schedule_id FROM msdb.dbo.sysjobschedules WHERE job_id=@managed);
EXEC msdb.dbo.sp_update_schedule @schedule_id=@schedule,@freq_subday_interval=17;
-- Job notifications use an existing operator only; missing operators are rejected and settings can be cleared.
EXEC msdb.dbo.sp_add_operator @name=N'DBADB_IT_Operator',@email_address=N'dba@example.invalid';
EXEC ops.usp_SetJobNotification @OperatorName=N'DBADB_IT_Operator';
IF EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id
    LEFT JOIN msdb.dbo.sysoperators o ON o.id=j.notify_email_operator_id
    WHERE j.notify_level_email<>2 OR ISNULL(o.name,N'')<>N'DBADB_IT_Operator')
    THROW 52000,'Job notification was not applied to every managed job.',1;
BEGIN TRY
    EXEC ops.usp_SetJobNotification @OperatorName=N'DBADB_IT_missing_operator';
    THROW 52000,'Missing operator should be rejected.',1;
END TRY
BEGIN CATCH IF ERROR_NUMBER()<>51000 THROW; END CATCH;
EXEC ops.usp_SetJobNotification;
IF EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id
    WHERE j.notify_level_email<>0 OR j.notify_email_operator_id<>0)
    THROW 52000,'Job notification was not cleared.',1;
EXEC ops.usp_SetJobNotification @OperatorName=N'DBADB_IT_Operator';
-- Job owner can move to another sysadmin login only.
CREATE LOGIN DBADB_IT_NonAdmin WITH PASSWORD=N'Dbadb_IT_49!NonAdmin_pw', CHECK_POLICY=OFF;
BEGIN TRY EXEC ops.usp_SetJobOwner @LoginName=N'DBADB_IT_NonAdmin'; THROW 52000,'Non-sysadmin owner accepted.',1; END TRY
BEGIN CATCH IF ERROR_NUMBER()<>51000 THROW; END CATCH;
CREATE LOGIN DBADB_IT_Owner WITH PASSWORD=N'Dbadb_IT_49!Owner_pw', CHECK_POLICY=OFF;
ALTER SERVER ROLE sysadmin ADD MEMBER DBADB_IT_Owner;
EXEC ops.usp_SetJobOwner @LoginName=N'DBADB_IT_Owner';
IF EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id WHERE j.owner_sid<>SUSER_SID(N'DBADB_IT_Owner'))
    THROW 52000,'Job owner was not changed.',1;
PRINT N'Integration assertions passed.';
GO

UPDATE cfg.BackupDefault SET filename_pattern=N'persist_[guid]' WHERE database_scope='USER' AND backup_type='D';
UPDATE cfg.BackupOverride SET filename_pattern=N'override_[guid]' WHERE database_name=N'DBADB_IT_LS' AND backup_type='D';
GO
