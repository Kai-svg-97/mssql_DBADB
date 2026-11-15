USE DBADB;
GO
CREATE OR ALTER VIEW report.AgentJobStatus AS
SELECT j.job_id,j.name AS job_name,j.enabled AS job_enabled,
    h.run_status AS last_run_status,h.message AS last_run_message,
    CASE WHEN h.run_date>0 THEN msdb.dbo.agent_datetime(h.run_date,h.run_time) END AS last_run_at,
    a.start_execution_date,a.stop_execution_date,
    CAST(CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 1 ELSE 0 END AS bit) AS is_running,
    j.notify_level_email,o.name AS notify_email_operator
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysoperators o ON o.id=j.notify_email_operator_id
OUTER APPLY (SELECT TOP(1) x.run_status,x.message,x.run_date,x.run_time FROM msdb.dbo.sysjobhistory x
    WHERE x.job_id=j.job_id AND x.step_id=0 ORDER BY x.instance_id DESC) h
LEFT JOIN msdb.dbo.sysjobactivity a ON a.job_id=j.job_id AND a.session_id=(SELECT MAX(session_id) FROM msdb.dbo.syssessions);
GO
CREATE OR ALTER VIEW report.ProjectSchedules AS
SELECT c.job_key,j.*,s.name AS schedule_name,s.enabled AS schedule_enabled,
    s.freq_type,s.freq_interval,s.freq_subday_type,s.freq_subday_interval,s.freq_recurrence_factor,
    s.active_start_date,s.active_end_date,s.active_start_time,s.active_end_time,
    CASE WHEN js.next_run_date>0 THEN msdb.dbo.agent_datetime(js.next_run_date,js.next_run_time) END AS agent_cached_next_run_at
FROM cfg.AgentJob c JOIN report.AgentJobStatus j ON j.job_id=c.job_id
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id=c.job_id
LEFT JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id;
GO
CREATE OR ALTER VIEW report.BackupSchedule AS
SELECT p.*,cfg.ufn_ScheduleSlotAt(SYSDATETIME(),p.anchor_date,p.start_time,p.interval_minutes) AS current_slot_at,
    DATEADD(minute,p.interval_minutes,cfg.ufn_ScheduleSlotAt(SYSDATETIME(),p.anchor_date,p.start_time,p.interval_minutes)) AS next_policy_slot_at,
    i.started_at AS last_attempt_at,i.status AS last_attempt_status,i.reason AS last_attempt_reason
FROM report.EffectiveBackupPolicy p OUTER APPLY(SELECT TOP(1) started_at,status,reason FROM ops.BackupItem b
    WHERE b.database_name=p.database_name AND b.database_guid=p.database_guid AND b.backup_type=p.backup_type ORDER BY started_at DESC) i;
GO
CREATE OR ALTER VIEW report.BackupHealth AS
SELECT p.database_name,p.backup_type,p.database_scope,p.exclusion_reason,p.interval_minutes,
    h.backup_finish_date AS last_success_at,i.status AS last_project_status,i.reason AS last_project_reason,
    f.started_at AS last_failure_at,f.reason AS last_failure_reason,
    -- UNPROTECTED: an enabled policy that cannot produce backups. Set the override enabled=0
    -- to record an intentional exclusion; only then does it become EXCLUDED.
    CASE WHEN p.exclusion_reason IN (N'AVAILABILITY_GROUP_NOT_SUPPORTED',N'DATABASE_NOT_ONLINE',N'BACKUP_DIRECTORY_NOT_CONFIGURED')
            AND p.enabled=1 THEN 'UNPROTECTED'
        WHEN p.exclusion_reason IS NOT NULL THEN 'EXCLUDED'
        WHEN i.status='SKIPPED' AND i.reason IN (N'INVALID_BACKUP_DIRECTORY_EXPECT_ABSOLUTE_WINDOWS_OR_UNC_PATH',
            N'BACKUP_PATH_TOO_LONG_MAX_259',N'DIFFERENTIAL_BASE_NOT_AVAILABLE_TAKE_REGULAR_FULL_BACKUP') THEN 'UNPROTECTED'
        WHEN f.started_at IS NOT NULL AND (h.backup_finish_date IS NULL OR f.started_at>h.backup_finish_date) THEN 'FAILED'
        WHEN h.backup_finish_date IS NULL THEN 'MISSING'
        WHEN DATEDIFF_BIG(minute,h.backup_finish_date,SYSDATETIME())>CONVERT(bigint,p.interval_minutes)*2 THEN 'OVERDUE'
        ELSE 'OK' END AS health_status
FROM report.EffectiveBackupPolicy p
OUTER APPLY(SELECT TOP(1) backup_finish_date FROM report.BackupHistory b
    WHERE b.database_name=p.database_name AND b.database_guid=p.database_guid AND b.backup_type=p.backup_type
    ORDER BY backup_finish_date DESC) h
OUTER APPLY(SELECT TOP(1) status,reason,started_at FROM ops.BackupItem b WHERE b.database_name=p.database_name
    AND b.database_guid=p.database_guid AND b.backup_type=p.backup_type AND b.status<>'RUNNING'
    AND ISNULL(b.reason,N'') NOT IN (N'ANOTHER_PROJECT_BACKUP_IS_RUNNING',N'EXTERNAL_BACKUP_CURRENTLY_RUNNING',N'ALREADY_ATTEMPTED_SCHEDULE_SLOT')
    ORDER BY started_at DESC) i
OUTER APPLY(SELECT TOP(1) reason,started_at FROM ops.BackupItem b WHERE b.database_name=p.database_name
    AND b.database_guid=p.database_guid AND b.backup_type=p.backup_type AND b.status='FAILED' ORDER BY started_at DESC) f;
GO
CREATE OR ALTER PROCEDURE ops.usp_CheckBackupHealth
AS
BEGIN
    /*
    용도: 백업 상태를 점검하며 문제가 있으면 목록과 오류 51004를 반환합니다. 매개변수는 없습니다.
    상태 코드: OK=정상, EXCLUDED=제외, FAILED=실패, UNPROTECTED=보호 불가,
     MISSING=성공 이력 없음, OVERDUE=허용 간격 초과. EXCLUDED는 오류 대상이 아닙니다.
    예제: EXEC ops.usp_CheckBackupHealth; -- Agent 또는 수동 점검
          SELECT * FROM report.BackupHealth WHERE health_status<>'OK'; -- 점검 전 상세 조회
    */
    SET NOCOUNT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    -- Persistent signal: backup jobs succeed again on the next idle tick after a failure,
    -- so this check keeps failing for as long as any policy remains unhealthy.
    SELECT * INTO #problems FROM report.BackupHealth
    WHERE health_status IN ('FAILED','UNPROTECTED','MISSING','OVERDUE');
    SELECT * FROM #problems ORDER BY health_status,database_name,backup_type;
    IF EXISTS(SELECT 1 FROM #problems)
    BEGIN
        DECLARE @summary nvarchar(400)=(SELECT STRING_AGG(CONVERT(nvarchar(400),health_status+'='+CONVERT(varchar(10),n)),N' ')
            WITHIN GROUP (ORDER BY health_status) FROM (SELECT health_status,COUNT(*) AS n FROM #problems GROUP BY health_status) x);
        DECLARE @message nvarchar(2048)=N'Backup health check found problems: '+@summary+N'. Query report.BackupHealth.';
        THROW 51004,@message,1;
    END;
END;
GO
CREATE OR ALTER PROCEDURE ops.usp_PurgeOperationalHistory @KeepDays int=90
AS
BEGIN
    /*
    용도: 오래된 제외 시도, 빈 실행 및 수집 실행 기록을 정리합니다. 백업 파일과 보관 백업 이력은 삭제하지 않습니다.
    매개변수: @KeepDays 보관 일수(기본 90, 최소 30). 긴 일정 슬롯 보호로 실제 기준일은 더 이전일 수 있습니다.
    코드: SKIPPED=제외된 시도만 정리, RUNNING=진행 중인 실행은 유지. 사용자 트랜잭션 밖에서 호출합니다.
    예제: EXEC ops.usp_PurgeOperationalHistory; -- 기본 90일
          EXEC ops.usp_PurgeOperationalHistory @KeepDays=180; -- 180일 보관
    */
    SET NOCOUNT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    IF @@TRANCOUNT<>0 THROW 51000,'Run purge outside a user transaction.',1;
    IF @KeepDays IS NULL OR @KeepDays<30 THROW 51000,'@KeepDays must be at least 30.',1;
    -- Removes only DBADB's own bookkeeping. SUCCEEDED/FAILED attempts are kept because they link
    -- backup files to runs; collect.BackupHistory is the permanent archive and is never purged.
    DECLARE @cutoff datetime2(3)=DATEADD(day,-@KeepDays,SYSDATETIME()),@items int,@runs int,@collections int,
        @longest int=(SELECT MAX(i) FROM (SELECT interval_minutes FROM cfg.BackupDefault
            UNION ALL SELECT interval_minutes FROM cfg.BackupOverride) x(i));
    -- Never delete rows that may still settle a current slot of a long-interval policy.
    IF DATEADD(minute,-2*@longest,SYSDATETIME())<@cutoff SET @cutoff=DATEADD(minute,-2*@longest,SYSDATETIME());
    DELETE ops.BackupItem WHERE status='SKIPPED' AND started_at<@cutoff;
    SET @items=@@ROWCOUNT;
    DELETE r FROM ops.BackupRun r WHERE r.started_at<@cutoff AND r.status<>'RUNNING'
        AND NOT EXISTS(SELECT 1 FROM ops.BackupItem i WHERE i.run_id=r.run_id);
    SET @runs=@@ROWCOUNT;
    DELETE collect.CollectionRun WHERE started_at<@cutoff AND status<>'RUNNING';
    SET @collections=@@ROWCOUNT;
    SELECT @cutoff AS purged_before,@items AS skipped_items_deleted,@runs AS empty_runs_deleted,@collections AS collection_runs_deleted;
END;
GO
CREATE OR ALTER VIEW report.RetentionCandidates AS
SELECT b.backup_set_uuid,b.database_name,b.backup_type,b.backup_finish_date,b.execution_source,
    m.family_sequence_number,m.mirror,m.physical_device_name,p.retention_days,
    CAST(CASE WHEN p.is_log_shipping_primary=1 OR p.is_log_shipping_secondary=1 THEN 1 ELSE 0 END AS bit) AS log_shipping_managed,
    CAST(0 AS bit) AS deletion_safety_verified
FROM report.BackupHistory b JOIN report.EffectiveBackupPolicy p ON p.database_name=b.database_name
    AND p.database_guid=b.database_guid AND p.backup_type=b.backup_type
LEFT JOIN report.BackupMedia m ON m.backup_set_uuid=b.backup_set_uuid
WHERE b.backup_finish_date<DATEADD(day,-p.retention_days,SYSDATETIME());
GO
CREATE OR ALTER VIEW report.DiskSpace AS
SELECT DISTINCT v.volume_mount_point,v.logical_volume_name,v.file_system_type,v.total_bytes,
    v.available_bytes,100.0*v.available_bytes/NULLIF(v.total_bytes,0) AS free_percent,
    SYSDATETIME() AS observed_at
FROM sys.master_files f CROSS APPLY sys.dm_os_volume_stats(f.database_id,f.file_id) v;
GO
CREATE OR ALTER VIEW report.ActiveRequests AS
SELECT r.session_id,s.login_name,s.host_name,s.program_name,DB_NAME(r.database_id) AS database_name,
    r.status,r.command,r.start_time,r.blocking_session_id,r.wait_type,r.wait_time,r.wait_resource,
    r.cpu_time,r.total_elapsed_time,r.reads,r.writes,r.logical_reads,r.percent_complete,t.text AS batch_text
FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE r.session_id<>@@SPID;
GO
CREATE OR ALTER VIEW report.LogShippingStatus AS
SELECT 'PRIMARY' AS local_role,p.primary_database AS database_name,
    CONVERT(sysname,SERVERPROPERTY('ServerName')) AS primary_server,p.primary_database,
    p.primary_id AS configuration_id,p.backup_directory,p.backup_share,
    p.backup_retention_period AS native_retention_minutes,
    p.last_backup_file,p.last_backup_date,m.last_backup_date_utc,
    m.backup_threshold AS threshold_minutes,
    DATEDIFF_BIG(minute,m.last_backup_date_utc,SYSUTCDATETIME()) AS minutes_since_last_operation,
    CAST(NULL AS datetime) AS last_copied_date,CAST(NULL AS datetime) AS last_restored_date,
    CAST(NULL AS int) AS restore_delay_minutes,CAST(NULL AS int) AS last_restored_latency_minutes,
    p.backup_job_id AS primary_job_id,CAST(NULL AS uniqueidentifier) AS restore_job_id,
    CASE WHEN m.last_backup_date_utc IS NULL THEN 'UNKNOWN'
        WHEN DATEDIFF_BIG(minute,m.last_backup_date_utc,SYSUTCDATETIME())>m.backup_threshold THEN 'OVERDUE' ELSE 'OK' END AS health_status
FROM msdb.dbo.log_shipping_primary_databases p
LEFT JOIN msdb.dbo.log_shipping_monitor_primary m ON m.primary_id=p.primary_id
UNION ALL
SELECT 'SECONDARY',d.secondary_database,s.primary_server,s.primary_database,d.secondary_id,
    NULL,NULL,NULL,NULL,NULL,NULL,m.restore_threshold,
    DATEDIFF_BIG(minute,m.last_restored_date_utc,SYSUTCDATETIME()),
    m.last_copied_date,m.last_restored_date,d.restore_delay,m.last_restored_latency,
    s.copy_job_id,s.restore_job_id,
    CASE WHEN m.last_restored_date_utc IS NULL THEN 'UNKNOWN'
        WHEN DATEDIFF_BIG(minute,m.last_restored_date_utc,SYSUTCDATETIME())>m.restore_threshold THEN 'OVERDUE' ELSE 'OK' END
FROM msdb.dbo.log_shipping_secondary_databases d JOIN msdb.dbo.log_shipping_secondary s ON s.secondary_id=d.secondary_id
LEFT JOIN msdb.dbo.log_shipping_monitor_secondary m ON m.secondary_id=d.secondary_id AND m.secondary_database=d.secondary_database;
GO
CREATE OR ALTER VIEW report.LogShippingJobs AS
SELECT s.local_role,s.database_name,'BACKUP_OR_COPY' AS operation,j.*
FROM report.LogShippingStatus s LEFT JOIN report.AgentJobStatus j ON j.job_id=s.primary_job_id
UNION ALL
SELECT s.local_role,s.database_name,'RESTORE',j.*
FROM report.LogShippingStatus s LEFT JOIN report.AgentJobStatus j ON j.job_id=s.restore_job_id
WHERE s.local_role='SECONDARY';
GO
CREATE OR ALTER VIEW report.LogShippingErrors AS
SELECT agent_id,agent_type,session_id,database_name,sequence_number,log_time,log_time_utc,message
FROM msdb.dbo.log_shipping_monitor_error_detail;
GO
CREATE OR ALTER VIEW report.LogShippingLogBackups AS
SELECT b.*,m.physical_device_name,m.family_sequence_number,m.mirror,
    p.backup_directory AS log_shipping_directory,
    CASE WHEN m.physical_device_name IS NULL THEN 'UNKNOWN'
        WHEN LEFT(m.physical_device_name,LEN(p.backup_directory)+CASE WHEN RIGHT(p.backup_directory,1)=N'\' THEN 0 ELSE 1 END)
            =p.backup_directory+CASE WHEN RIGHT(p.backup_directory,1)=N'\' THEN N'' ELSE N'\' END THEN 'EXPECTED_DIRECTORY'
        ELSE 'REVIEW_LOCATION' END AS location_assessment,
    CAST(CASE WHEN b.item_id IS NOT NULL THEN 1 ELSE 0 END AS bit) AS project_backup_needs_investigation
FROM report.BackupHistory b
JOIN msdb.dbo.log_shipping_primary_databases p ON p.primary_database=b.database_name
LEFT JOIN report.BackupMedia m ON m.backup_set_uuid=b.backup_set_uuid
WHERE b.backup_type='L';
GO
CREATE OR ALTER PROCEDURE ops.usp_StartLogShippingBackup
    @DatabaseName sysname,@Execute bit=0
AS
BEGIN
    /*
    용도: 로컬 로그 시핑 기본 DB의 기존 활성 백업 작업을 확인하거나 비동기로 시작합니다.
    매개변수: @DatabaseName 로그 시핑 기본 DB명; @Execute 실행 여부(기본 0).
    코드: @Execute 0=작업 확인만, 1=기존 네이티브 작업 시작. 네이티브 보존 정책이 적용될 수 있습니다.
    예제: EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales'; -- 작업 확인
          EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales',@Execute=1; -- 작업 시작
    */
    SET NOCOUNT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    DECLARE @job uniqueidentifier;
    SELECT @job=p.backup_job_id FROM msdb.dbo.log_shipping_primary_databases p WHERE p.primary_database=@DatabaseName;
    IF @job IS NULL THROW 51000,'Local log shipping primary configuration not found.',1;
    IF NOT EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE job_id=@job AND enabled=1)
        THROW 51000,'Log shipping backup job is missing or disabled. Investigate before starting it.',1;
    SELECT @DatabaseName AS database_name,@job AS native_job_id,@Execute AS execution_requested;
    IF @Execute=1 EXEC msdb.dbo.sp_start_job @job_id=@job;
END;
GO
