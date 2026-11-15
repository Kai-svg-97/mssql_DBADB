USE DBADB;
GO
CREATE OR ALTER PROCEDURE ops.usp_Backup
    @BackupType char(1)='D',
    @DatabaseScope varchar(6)='USER',
    @DatabaseName sysname=NULL,
    @RespectSchedule bit=0,
    @RunId uniqueidentifier=NULL OUTPUT
AS
BEGIN
    /*
    용도: 정책과 보호 조건에 따라 실제 백업을 수행하고 실행 이력을 남깁니다.
    매개변수: @BackupType 백업 종류(기본 D); @DatabaseScope 범위(기본 USER);
     @DatabaseName DB명(NULL이면 범위 전체); @RespectSchedule 일정 적용 여부(기본 0);
     @RunId 실행 ID 출력(대상이 없으면 NULL). sysadmin으로 사용자 트랜잭션 밖에서 호출합니다.
    코드: @BackupType D=전체, I=차등, L=로그; @DatabaseScope USER=사용자 DB, SYSTEM=시스템 DB;
     @RespectSchedule 0=수동 실행, 1=슬롯·재시도·지연 제한 적용.
    예제: EXEC ops.usp_Backup @BackupType='D',@DatabaseName=N'Sales';
          EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'Sales';
          DECLARE @id uniqueidentifier; EXEC ops.usp_Backup @BackupType='D',@DatabaseScope='SYSTEM',@RespectSchedule=1,@RunId=@id OUTPUT;
          SELECT @id AS 실행ID;
    */
    SET NOCOUNT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required; metadata visibility must be complete.',1;
    IF @@TRANCOUNT<>0 THROW 51000,'BACKUP must run outside a user transaction.',1;
    IF @BackupType IS NULL OR @BackupType NOT IN ('D','I','L') OR @DatabaseScope IS NULL OR @DatabaseScope NOT IN ('USER','SYSTEM') OR @RespectSchedule IS NULL
        THROW 51000,'Invalid backup arguments.',1;
    IF @DatabaseName IS NOT NULL AND NOT EXISTS(SELECT 1 FROM report.EffectiveBackupPolicy
        WHERE database_name=@DatabaseName AND backup_type=@BackupType AND database_scope=@DatabaseScope)
        THROW 51000,'Database not found in requested scope.',1;
    -- Close interrupted attempts so retry limits and health reporting see them:
    --  * this session's own RUNNING runs: a session runs one batch at a time, so they were aborted
    --    by a cancel/timeout (attention bypasses CATCH); release any backup locks they leaked;
    --  * runs whose session ended (KILL, Agent stop, restart): SQL Server released their locks;
    --  * runs whose session is alive but idle: aborted; that session may still hold the lock
    --    until it disconnects or runs DBADB again, so the reason names it;
    --  * pre-v2 runs (no session recorded) started before the last instance restart.
    DECLARE @me_login datetime=(SELECT login_time FROM sys.dm_exec_sessions WHERE session_id=@@SPID),
        @orphan_res nvarchar(255);
    SELECT DISTINCT N'DBADB:Backup:'+CASE WHEN i.backup_type='L' THEN N'L:' ELSE N'' END+CONVERT(nvarchar(10),DB_ID(i.database_name)) AS resource
    INTO #own_locks FROM ops.BackupRun r JOIN ops.BackupItem i ON i.run_id=r.run_id
    WHERE r.status='RUNNING' AND r.session_id=@@SPID AND r.session_login_time=@me_login AND DB_ID(i.database_name) IS NOT NULL;
    SELECT r.run_id,CASE
            WHEN r.session_id=@@SPID AND r.session_login_time=@me_login THEN N'ATTEMPT_ABORTED_IN_THIS_SESSION'
            WHEN r.session_id IS NULL THEN N'ATTEMPT_INTERRUPTED_BEFORE_INSTANCE_RESTART'
            WHEN NOT EXISTS(SELECT 1 FROM sys.dm_exec_sessions x WHERE x.session_id=r.session_id AND x.login_time=r.session_login_time)
                THEN N'ATTEMPT_INTERRUPTED_SESSION_ENDED'
            ELSE N'ATTEMPT_ABORTED_SESSION_'+CONVERT(nvarchar(10),r.session_id)+N'_IDLE_MAY_HOLD_BACKUP_LOCK' END AS reason
    INTO #orphans FROM ops.BackupRun r
    WHERE r.status='RUNNING' AND (
        (r.session_id=@@SPID AND r.session_login_time=@me_login)
        OR (r.session_id IS NULL AND r.started_at<(SELECT sqlserver_start_time FROM sys.dm_os_sys_info))
        OR (r.session_id IS NOT NULL AND r.session_id<>@@SPID AND NOT EXISTS(SELECT 1 FROM sys.dm_exec_requests q WHERE q.session_id=r.session_id)));
    UPDATE i SET status='FAILED',finished_at=SYSDATETIME(),reason=o.reason
    FROM #orphans o JOIN ops.BackupItem i ON i.run_id=o.run_id WHERE i.status='RUNNING';
    UPDATE r SET finished_at=SYSDATETIME(),error_message=o.reason,
        status=CASE WHEN EXISTS(SELECT 1 FROM ops.BackupItem i WHERE i.run_id=r.run_id AND i.status='SUCCEEDED') THEN 'PARTIAL' ELSE 'FAILED' END
    FROM #orphans o JOIN ops.BackupRun r ON r.run_id=o.run_id;
    DECLARE own_locks CURSOR LOCAL FAST_FORWARD FOR SELECT resource FROM #own_locks;
    OPEN own_locks; FETCH NEXT FROM own_locks INTO @orphan_res;
    WHILE @@FETCH_STATUS=0
    BEGIN
        WHILE APPLOCK_MODE(N'public',@orphan_res,N'Session')<>N'NoLock'
            EXEC sys.sp_releaseapplock @Resource=@orphan_res,@LockOwner='Session';
        FETCH NEXT FROM own_locks INTO @orphan_res;
    END;
    CLOSE own_locks; DEALLOCATE own_locks;
    -- Include excluded databases so scheduled runs record the reason once per slot.
    -- Transient offline/identity exclusions use the configured retry policy.
    SELECT p.database_name INTO #targets FROM report.EffectiveBackupPolicy p
    WHERE p.backup_type=@BackupType AND p.database_scope=@DatabaseScope
        AND (@DatabaseName IS NULL OR p.database_name=@DatabaseName)
        AND (@RespectSchedule=0 OR EXISTS(SELECT 1 FROM ops.ufn_SlotDue(p.database_name,p.database_guid,p.backup_type,
            cfg.ufn_ScheduleSlotAt(SYSDATETIME(),p.anchor_date,p.start_time,p.interval_minutes),p.retry_count,p.retry_interval_minutes,
            p.catch_up_minutes,SYSDATETIME(),NULL) d WHERE d.is_due=1));
    IF NOT EXISTS(SELECT 1 FROM #targets) BEGIN SET @RunId=NULL; RETURN; END;
    SET @RunId=NEWID();
    INSERT ops.BackupRun(run_id,backup_type,database_scope,requested_database,respect_schedule,status,session_id,session_login_time)
    SELECT @RunId,@BackupType,@DatabaseScope,@DatabaseName,@RespectSchedule,'RUNNING',@@SPID,login_time
    FROM sys.dm_exec_sessions WHERE session_id=@@SPID;
    DECLARE @run_text nvarchar(36)=CONVERT(nvarchar(36),@RunId);
    RAISERROR(N'DBADB run %s started.',10,1,@run_text) WITH NOWAIT;
    DECLARE @db sysname,@guid uniqueidentifier,@dbid int,@item uniqueidentifier,
        @cmd nvarchar(max),@path nvarchar(1500),@reason nvarchar(2048),@lock int,
        @resource nvarchar(255),@held bit=0,@slot datetime2(0),@status varchar(12),@err int,
        @retries int,@retry_interval int;
    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
        SELECT database_name FROM #targets;
    BEGIN TRY
        OPEN dbs; FETCH NEXT FROM dbs INTO @db;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SELECT @item=NEWID(),@held=0,@lock=-999,@err=NULL,@cmd=NULL,@path=NULL,@reason=NULL,@guid=NULL,@dbid=NULL,
                @slot=NULL,@retries=NULL,@retry_interval=NULL;
            SELECT @guid=database_guid,@dbid=database_id,@retries=retry_count,@retry_interval=retry_interval_minutes,
                @slot=cfg.ufn_ScheduleSlotAt(SYSDATETIME(),anchor_date,start_time,interval_minutes)
            FROM report.EffectiveBackupPolicy WHERE database_name=@db AND backup_type=@BackupType;
            -- Full and differential backups of one database are mutually exclusive in the engine, and so
            -- are two log backups; a log backup may run during a full or differential backup. One lock
            -- for D/I and a separate lock for L keeps log backups (and RPO) going during long fulls.
            -- Locks are released by SQL Server on disconnect.
            SET @resource=N'DBADB:Backup:'+CASE WHEN @BackupType='L' THEN N'L:' ELSE N'' END+CONVERT(nvarchar(10),@dbid);
            INSERT ops.BackupItem(item_id,run_id,database_name,database_guid,backup_type,status,backup_name)
                VALUES(@item,@RunId,@db,@guid,@BackupType,'RUNNING',N'DBADB:'+CONVERT(nvarchar(36),@item));
            BEGIN TRY
                EXEC @lock=sys.sp_getapplock @Resource=@resource,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
                IF @lock<0 SET @reason=N'ANOTHER_PROJECT_BACKUP_IS_RUNNING';
                ELSE
                BEGIN
                    SET @held=1;
                    -- catch_up_minutes was applied when the run started (#targets); re-applying it per
                    -- database would silently skip the tail of a long serial run every day.
                    IF @RespectSchedule=1 AND NOT EXISTS(SELECT 1 FROM ops.ufn_SlotDue(@db,@guid,@BackupType,@slot,
                        @retries,@retry_interval,0,SYSDATETIME(),@item) WHERE is_due=1)
                        SET @reason=N'ALREADY_ATTEMPTED_SCHEDULE_SLOT';
                    IF @reason IS NULL
                    BEGIN
                        -- Re-read policy and local log shipping metadata under the lock, even for manual runs.
                        EXEC ops.usp_PlanBackup @db,@BackupType,@item,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT;
                        IF @reason IS NULL AND (DB_ID(@db)<>@dbid OR NOT EXISTS(
                            SELECT 1 FROM sys.database_recovery_status WHERE database_id=@dbid AND database_guid=@guid))
                            SET @reason=N'DATABASE_IDENTITY_CHANGED';
                        -- Only a conflicting external backup blocks: log vs log, database vs database.
                        IF @reason IS NULL AND EXISTS(SELECT 1 FROM sys.dm_exec_requests WHERE database_id=@dbid
                            AND session_id<>@@SPID AND command LIKE CASE WHEN @BackupType='L' THEN N'BACKUP LOG%' ELSE N'BACKUP DATABASE%' END)
                            SET @reason=N'EXTERNAL_BACKUP_CURRENTLY_RUNNING';
                        IF @reason IS NULL
                        BEGIN
                            UPDATE ops.BackupItem SET command=@cmd,backup_path=@path WHERE item_id=@item;
                            EXEC sys.sp_executesql @cmd;
                        END;
                    END;
                END;
                SET @status=CASE WHEN @reason IS NULL THEN 'SUCCEEDED' ELSE 'SKIPPED' END;
            END TRY
            BEGIN CATCH
                SELECT @status='FAILED',@reason=ERROR_MESSAGE(),@err=ERROR_NUMBER();
            END CATCH;
            -- Persist the outcome before releasing the lock so a second scheduled
            -- session cannot see a completed backup as still RUNNING and repeat it.
            UPDATE ops.BackupItem SET status=@status,reason=@reason,error_number=@err,
                command=@cmd,backup_path=@path,finished_at=SYSDATETIME() WHERE item_id=@item;
            IF @held=1
            BEGIN
                EXEC sys.sp_releaseapplock @Resource=@resource,@LockOwner='Session';
                SET @held=0;
            END;
            FETCH NEXT FROM dbs INTO @db;
        END;
        CLOSE dbs; DEALLOCATE dbs;
        UPDATE ops.BackupRun SET finished_at=SYSDATETIME(),status=CASE
            WHEN EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@RunId AND status='FAILED') THEN
                CASE WHEN EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@RunId AND status='SUCCEEDED') THEN 'PARTIAL' ELSE 'FAILED' END
            ELSE 'SUCCEEDED' END WHERE run_id=@RunId;
    END TRY
    BEGIN CATCH
        -- Persist the outcome before releasing the lock, as on the normal path.
        UPDATE ops.BackupItem SET status='FAILED',finished_at=SYSDATETIME(),reason=ERROR_MESSAGE(),error_number=ERROR_NUMBER()
            WHERE run_id=@RunId AND status='RUNNING';
        IF @held=1 EXEC sys.sp_releaseapplock @Resource=@resource,@LockOwner='Session';
        IF CURSOR_STATUS('local','dbs')>=0 CLOSE dbs;
        IF CURSOR_STATUS('local','dbs')>-3 DEALLOCATE dbs;
        UPDATE ops.BackupRun SET status='FAILED',finished_at=SYSDATETIME(),error_message=ERROR_MESSAGE() WHERE run_id=@RunId;
        THROW;
    END CATCH;
    -- Report failure to Agent AFTER processing the other databases.
    IF EXISTS(SELECT 1 FROM ops.BackupRun WHERE run_id=@RunId AND status IN ('FAILED','PARTIAL'))
    BEGIN
        DECLARE @failure nvarchar(2048)=N'One or more backups failed. Query ops.BackupItem for run_id '+@run_text+N'.';
        THROW 51002,@failure,1;
    END;
END;
GO
