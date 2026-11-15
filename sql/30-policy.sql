USE DBADB;
GO
CREATE OR ALTER VIEW report.EffectiveBackupPolicy
AS
WITH p AS (
    SELECT d.database_id,d.name AS database_name,rs.database_guid,
        CASE WHEN d.database_id<=4 THEN 'SYSTEM' ELSE 'USER' END AS database_scope,
        d.state_desc,d.recovery_model_desc,d.is_read_only,d.is_in_standby,d.source_database_id,d.group_database_id,
        b.backup_type,COALESCE(o.enabled,b.enabled) AS enabled,
        COALESCE(o.directory,b.directory) AS directory,
        COALESCE(o.filename_pattern,b.filename_pattern) AS filename_pattern,
        COALESCE(o.interval_minutes,b.interval_minutes) AS interval_minutes,
        COALESCE(o.start_time,b.start_time) AS start_time,
        COALESCE(o.anchor_date,b.anchor_date) AS anchor_date,
        COALESCE(o.catch_up_minutes,b.catch_up_minutes) AS catch_up_minutes,
        COALESCE(o.retention_days,b.retention_days) AS retention_days,
        COALESCE(o.compression,b.compression) AS compression,
        COALESCE(o.checksum,b.checksum) AS checksum,
        COALESCE(o.retry_count,b.retry_count) AS retry_count,
        COALESCE(o.retry_interval_minutes,b.retry_interval_minutes) AS retry_interval_minutes,
        -- Primary full backups are copy-only to avoid replacing another tool's differential base.
        CAST(CASE WHEN lp.primary_id IS NOT NULL AND b.backup_type='D' THEN 1
            ELSE COALESCE(o.copy_only,b.copy_only) END AS bit) AS copy_only,
        CAST(CASE WHEN lp.primary_id IS NOT NULL THEN 1 ELSE 0 END AS bit) AS is_log_shipping_primary,
        CAST(CASE WHEN ls.secondary_id IS NOT NULL THEN 1 ELSE 0 END AS bit) AS is_log_shipping_secondary,
        o.note
    FROM sys.databases d
    JOIN cfg.BackupDefault b ON b.database_scope=CASE WHEN d.database_id<=4 THEN 'SYSTEM' ELSE 'USER' END
    LEFT JOIN cfg.BackupOverride o ON o.database_name=d.name COLLATE DATABASE_DEFAULT AND o.backup_type=b.backup_type
    LEFT JOIN sys.database_recovery_status rs ON rs.database_id=d.database_id
    LEFT JOIN msdb.dbo.log_shipping_primary_databases lp ON lp.primary_database=d.name COLLATE DATABASE_DEFAULT
    LEFT JOIN msdb.dbo.log_shipping_secondary_databases ls ON ls.secondary_database=d.name COLLATE DATABASE_DEFAULT
)
SELECT p.*,
    CAST(CASE
        WHEN database_id=2 THEN N'TEMPDB_NOT_SUPPORTED'
        WHEN source_database_id IS NOT NULL THEN N'DATABASE_SNAPSHOT'
        WHEN group_database_id IS NOT NULL THEN N'AVAILABILITY_GROUP_NOT_SUPPORTED'
        WHEN is_log_shipping_secondary=1 THEN N'LOG_SHIPPING_SECONDARY'
        WHEN backup_type='L' AND is_log_shipping_primary=1 THEN N'LOG_SHIPPING_PRIMARY_OWNS_LOG_BACKUPS'
        WHEN database_scope='SYSTEM' AND backup_type<>'D' THEN N'SYSTEM_DATABASE_FULL_ONLY'
        WHEN enabled=0 THEN N'POLICY_DISABLED'
        WHEN state_desc<>'ONLINE' THEN N'DATABASE_NOT_ONLINE'
        WHEN is_in_standby=1 THEN N'DATABASE_IN_STANDBY'
        WHEN backup_type='L' AND recovery_model_desc='SIMPLE' THEN N'SIMPLE_RECOVERY_NO_LOG_BACKUP'
        WHEN NULLIF(LTRIM(RTRIM(directory)),N'') IS NULL THEN N'BACKUP_DIRECTORY_NOT_CONFIGURED'
        ELSE NULL END AS nvarchar(2048)) AS exclusion_reason
FROM p;
GO
CREATE OR ALTER FUNCTION cfg.ufn_ScheduleSlotAt(@now datetime2(3),@anchor_date date,@start_time time(0),@interval_minutes int)
RETURNS datetime2(0)
AS
BEGIN
    /*
    용도: 기준일과 시작 시각으로 현재에 해당하는 최근 일정 슬롯을 계산합니다.
    매개변수: @now 기준 서버 현지 시각; @anchor_date 일정 기준일; @start_time 하루 시작 시각;
               @interval_minutes 반복 간격(분, 양수).
    예제: SELECT cfg.ufn_ScheduleSlotAt('2026-11-14T01:59:59.700','20000101','02:00',1440); -- 전날 02시
          SELECT cfg.ufn_ScheduleSlotAt('2026-11-14T10:00:00','20000102','02:00',10080); -- 일요일 02시
    */
    -- Fixed local-time grid from anchor_date + start_time; the anchor's weekday fixes weekly slots.
    -- DATEDIFF counts minute boundaries, so fractional seconds never round into the next slot.
    DECLARE @anchor datetime2(0)=DATEADD(second,DATEDIFF(second,CAST('00:00' AS time),@start_time),CAST(@anchor_date AS datetime2(0)));
    DECLARE @minutes int=DATEDIFF(minute,@anchor,@now);
    DECLARE @slots int=@minutes/@interval_minutes;
    -- Floor division for an anchor in the future, so the slot never lies after @now.
    IF @minutes<0 AND @minutes%@interval_minutes<>0 SET @slots-=1;
    RETURN DATEADD(minute,@slots*@interval_minutes,@anchor);
END;
GO
-- v1 signature kept so a v1 procedure still running during an upgrade keeps working.
CREATE OR ALTER FUNCTION cfg.ufn_ScheduleSlot(@now datetime2(3),@start_time time(0),@interval_minutes int)
RETURNS datetime2(0)
AS
BEGIN
    /*
    용도: 기존 버전 호환용 슬롯 계산입니다. 기준일은 2000-01-01입니다.
    매개변수: @now 기준 서버 현지 시각; @start_time 하루 시작 시각; @interval_minutes 반복 간격(분, 양수).
    예제: SELECT cfg.ufn_ScheduleSlot('2026-11-14T02:15:00','02:00',1440); -- 매일
          SELECT cfg.ufn_ScheduleSlot('2026-11-14T02:14:00','00:00',15); -- 15분 간격
    */
    RETURN cfg.ufn_ScheduleSlotAt(@now,'20000101',@start_time,@interval_minutes);
END;
GO
CREATE OR ALTER FUNCTION ops.ufn_SlotDue(@DatabaseName sysname,@DatabaseGuid uniqueidentifier,@BackupType char(1),
    @Slot datetime2(0),@RetryCount int,@RetryIntervalMinutes int,@CatchUpMinutes int,@Now datetime2(3),@ExcludeItemId uniqueidentifier)
RETURNS TABLE
AS
RETURN
    /*
    용도: 동일 DB 식별자의 슬롯 이력과 재시도 설정으로 실행 대상 여부를 계산하는 내부 함수입니다.
    매개변수: @DatabaseName DB명; @DatabaseGuid DB 식별 GUID(NULL 허용); @BackupType 백업 종류;
     @Slot 슬롯 시작 시각; @RetryCount 최초 시도 외 재시도 횟수; @RetryIntervalMinutes 재시도 간격(분);
     @CatchUpMinutes 슬롯 시작 후 실행 허용 시간(분, 0은 제한 없음); @Now 판단 시각;
     @ExcludeItemId 판단에서 제외할 현재 시도 ID(NULL이면 제외 없음).
    코드: @BackupType D=전체, I=차등, L=로그; 결과 is_due 1=실행 대상, 0=대상 아님.
    예제: DECLARE @g uniqueidentifier=(SELECT database_guid FROM sys.database_recovery_status WHERE database_id=DB_ID(N'Sales'));
          SELECT * FROM ops.ufn_SlotDue(N'Sales',@g,'D','2026-11-14T02:00:00',2,15,180,'2026-11-14T02:30:00',NULL);
          SELECT * FROM ops.ufn_SlotDue(N'Sales',@g,'L','2026-11-14T02:15:00',0,15,0,'2026-11-14T02:16:00',NULL);
    */
-- A slot is settled by any success or by an exclusion recorded by a scheduled run (manual
-- runs record exclusions for information only). Scheduled failures and
-- transient state skips (database not online / replaced) are retried inside the same slot once
-- retry_interval_minutes have passed since the attempt FINISHED, at most retry_count extra times.
-- Manual failures neither consume retries nor delay them. With catch_up_minutes>0 no run
-- starts later than that after the slot start (first attempts and retries alike); the caller
-- applies it once per run, so a long serial run started in time finishes all its databases. Lock/external-backup skips and
-- lost-race skips never count; the real attempt in that slot decides.
WITH a AS (
    SELECT i.status,COALESCE(i.finished_at,i.started_at) AS ended_at,
        -- Rows written before v2 (no session_id) keep v1 meaning: any outcome settles the slot,
        -- so installing v2 never turns an earlier failure into a daytime retry.
        CASE WHEN r.session_id IS NOT NULL AND (i.status='FAILED' OR i.reason IN (N'DATABASE_NOT_ONLINE',N'DATABASE_IDENTITY_CHANGED'))
            THEN 1 ELSE 0 END AS retryable,
        r.respect_schedule,r.session_id
    FROM ops.BackupItem i JOIN ops.BackupRun r ON r.run_id=i.run_id
    WHERE i.database_name=@DatabaseName AND i.backup_type=@BackupType
        AND (i.database_guid=@DatabaseGuid OR (i.database_guid IS NULL AND @DatabaseGuid IS NULL))
        AND i.started_at>=@Slot AND (@ExcludeItemId IS NULL OR i.item_id<>@ExcludeItemId)
        AND i.status IN ('SUCCEEDED','FAILED','SKIPPED')
        AND ISNULL(i.reason,N'') NOT IN (N'ANOTHER_PROJECT_BACKUP_IS_RUNNING',N'EXTERNAL_BACKUP_CURRENTLY_RUNNING',N'ALREADY_ATTEMPTED_SCHEDULE_SLOT')
)
SELECT CAST(CASE WHEN (ISNULL(@CatchUpMinutes,0)=0 OR @Now<DATEADD(minute,@CatchUpMinutes,@Slot))
        AND COUNT(CASE WHEN retryable=0 AND (status='SUCCEEDED' OR respect_schedule=1 OR session_id IS NULL) THEN 1 END)=0
        AND (COUNT(CASE WHEN retryable=1 AND respect_schedule=1 THEN 1 END)=0
            OR (COUNT(CASE WHEN retryable=1 AND respect_schedule=1 THEN 1 END)<=@RetryCount
                AND MAX(CASE WHEN retryable=1 AND respect_schedule=1 THEN ended_at END)<=DATEADD(minute,-@RetryIntervalMinutes,@Now)))
    THEN 1 ELSE 0 END AS bit) AS is_due,
    COUNT(CASE WHEN retryable=1 AND respect_schedule=1 THEN 1 END) AS scheduled_failed_attempts
FROM a;
GO
CREATE OR ALTER PROCEDURE ops.usp_PlanBackup
    @DatabaseName sysname,
    @BackupType char(1),
    @ItemId uniqueidentifier,
    @Command nvarchar(max) OUTPUT,
    @Path nvarchar(1500) OUTPUT,
    @Reason nvarchar(2048) OUTPUT,
    @StartedAt datetime2(3)=NULL
AS
BEGIN
    /*
    용도: 단일 DB의 정책과 보호 조건을 검사하여 백업 명령과 경로를 생성합니다. 백업은 실행하지 않습니다.
    매개변수: @DatabaseName DB명; @BackupType 백업 종류; @ItemId 시도 GUID;
     @Command 생성 명령 출력; @Path 생성 경로 출력; @Reason 제외 사유 출력(NULL이면 생성 성공);
     @StartedAt 예시 시작 시각(NULL이면 해당 시도 이력의 시작 시각, 없으면 현재 시각).
    코드: @BackupType D=전체, I=차등, L=로그. 실제 실행은 ops.usp_Backup을 사용합니다.
    예제: DECLARE @c nvarchar(max),@p nvarchar(1500),@r nvarchar(2048),@id uniqueidentifier=NEWID();
          EXEC ops.usp_PlanBackup N'Sales','D',@id,@c OUTPUT,@p OUTPUT,@r OUTPUT;
          SELECT @c AS 명령,@p AS 경로,@r AS 제외사유;
          EXEC ops.usp_PlanBackup N'Sales','L',@id,@c OUTPUT,@p OUTPUT,@r OUTPUT,'2026-11-14T01:59:59.700';
          SELECT @c AS 명령,@p AS 경로,@r AS 제외사유;
    */
    SET NOCOUNT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required for complete safety metadata.',1;
    DECLARE @dir nvarchar(1000),@compression bit,@checksum bit,@copy bit,@id int,@pattern nvarchar(1000);
    SELECT @Command=NULL,@Path=NULL,@Reason=NULL;
    SELECT @dir=directory,@pattern=filename_pattern,@compression=compression,@checksum=checksum,@copy=copy_only,
        @id=database_id,@Reason=exclusion_reason
    FROM report.EffectiveBackupPolicy WHERE database_name=@DatabaseName AND backup_type=@BackupType;
    IF @id IS NULL SET @Reason=N'DATABASE_OR_POLICY_NOT_FOUND';
    IF @Reason IS NOT NULL RETURN;
    IF @BackupType='I' AND NOT EXISTS (SELECT 1 FROM sys.master_files WHERE database_id=@id
        AND file_id=1 AND differential_base_lsn>0)
        SET @Reason=N'DIFFERENTIAL_BASE_NOT_AVAILABLE_TAKE_REGULAR_FULL_BACKUP';
    -- Only absolute Windows disk / UNC paths; directories are provisioned by the operator.
    IF NOT (@dir LIKE N'[A-Za-z]:\%' OR (@dir LIKE N'\\%\%' AND LEN(@dir)>5))
        OR @dir LIKE N'%..\%' OR @dir LIKE N'%[<>|"*?]%'
        SET @Reason=N'INVALID_BACKUP_DIRECTORY_EXPECT_ABSOLUTE_WINDOWS_OR_UNC_PATH';
    IF @Reason IS NOT NULL RETURN;
    IF RIGHT(@dir,1)<>N'\' SET @dir+=N'\';
    -- Validate the template before expansion, using a binary collation for exact tokens.
    DECLARE @remaining nvarchar(max)=@pattern COLLATE Latin1_General_100_BIN2;
    IF NULLIF(LTRIM(RTRIM(@pattern)),N'') IS NULL
        SET @Reason=N'EMPTY_FILENAME_PATTERN';
    ELSE IF CHARINDEX(N'[guid]',@remaining COLLATE Latin1_General_100_BIN2)=0
        SET @Reason=N'FILENAME_PATTERN_REQUIRES_GUID';
    SET @remaining=REPLACE(REPLACE(REPLACE(REPLACE(@remaining COLLATE Latin1_General_100_BIN2,
        N'[db_name]',N''),N'[db_id]',N''),N'[guid]',N''),N'[yyyymmddHHmi]',N'');
    IF @Reason IS NULL AND (@remaining LIKE N'%[[]%' OR @remaining LIKE N'%[]]%')
        SET @Reason=N'UNKNOWN_FILENAME_PATTERN_TOKEN';
    IF @Reason IS NULL AND (@remaining LIKE N'%[\/:*?"<>|]%' OR RIGHT(@pattern,4) COLLATE Latin1_General_100_CI_AS IN (N'.bak',N'.trn'))
        SET @Reason=N'INVALID_FILENAME_PATTERN';
    DECLARE @i int=1;
    WHILE @Reason IS NULL AND @i<=DATALENGTH(@remaining)/2
    BEGIN
        IF UNICODE(SUBSTRING(@remaining,@i,1))<32 SET @Reason=N'INVALID_FILENAME_PATTERN';
        SET @i+=1;
    END;
    IF @Reason IS NOT NULL RETURN;
    -- The item row is inserted at the start of each database attempt. Preview supplies its own time.
    IF @StartedAt IS NULL SELECT @StartedAt=started_at FROM ops.BackupItem WHERE item_id=@ItemId;
    IF @StartedAt IS NULL SET @StartedAt=SYSDATETIME();
    DECLARE @safe nvarchar(80)=LEFT(TRANSLATE(@DatabaseName,N'\/:*?"<>|',N'_________'),80),
        @filename nvarchar(max),@stamp nvarchar(12);
    SET @stamp=CONVERT(nvarchar(8),@StartedAt,112)+REPLACE(CONVERT(nvarchar(5),@StartedAt,108),N':',N'');
    SET @filename=REPLACE(REPLACE(REPLACE(REPLACE(CAST(@pattern AS nvarchar(max)) COLLATE Latin1_General_100_BIN2,
        N'[db_id]',CONVERT(nvarchar(10),@id)),N'[guid]',REPLACE(CONVERT(nvarchar(36),@ItemId),N'-',N'')),
        N'[yyyymmddHHmi]',@stamp),N'[db_name]',@safe);
    SET @filename+=CASE @BackupType WHEN 'L' THEN N'.trn' ELSE N'.bak' END;
    -- Windows reserves device names even when followed by an extension.
    DECLARE @stem nvarchar(255)=UPPER(LEFT(@filename,CHARINDEX(N'.',@filename+N'.')-1));
    IF @filename LIKE N'%[\/:*?"<>|]%' OR DATALENGTH(@filename)/2>255
        OR @stem IN (N'CON',N'PRN',N'AUX',N'NUL',N'COM1',N'COM2',N'COM3',N'COM4',N'COM5',N'COM6',N'COM7',N'COM8',N'COM9',N'LPT1',N'LPT2',N'LPT3',N'LPT4',N'LPT5',N'LPT6',N'LPT7',N'LPT8',N'LPT9')
        OR RIGHT(@pattern,1) IN (N'.',N' ')
        SET @Reason=N'INVALID_BACKUP_FILENAME';
    SET @i=1;
    WHILE @Reason IS NULL AND @i<=DATALENGTH(@filename)/2
    BEGIN
        IF UNICODE(SUBSTRING(@filename,@i,1))<32 SET @Reason=N'INVALID_BACKUP_FILENAME';
        SET @i+=1;
    END;
    IF @Reason IS NOT NULL RETURN;
    IF DATALENGTH(@dir+@filename)/2>259 BEGIN SET @Reason=N'BACKUP_PATH_TOO_LONG_MAX_259'; RETURN; END;
    SET @Path=@dir+@filename;
    SET @Command=N'BACKUP '+CASE @BackupType WHEN 'L' THEN N'LOG ' ELSE N'DATABASE ' END
        +QUOTENAME(@DatabaseName)+N' TO DISK = N'''+REPLACE(@Path,N'''',N'''''')+N''' WITH '
        +CASE WHEN @BackupType='I' THEN N'DIFFERENTIAL, ' ELSE N'' END
        +CASE WHEN @copy=1 THEN N'COPY_ONLY, ' ELSE N'' END
        +CASE WHEN @compression=1 THEN N'COMPRESSION, ' ELSE N'NO_COMPRESSION, ' END
        +CASE WHEN @checksum=1 THEN N'CHECKSUM, ' ELSE N'NO_CHECKSUM, ' END
        +N'NAME = N''DBADB:'+CONVERT(nvarchar(36),@ItemId)+N''', STATS = 10;';
END;
GO
CREATE OR ALTER PROCEDURE ops.usp_PreviewBackup
    @BackupType char(1)='D',@DatabaseScope varchar(6)='USER',@DatabaseName sysname=NULL
AS
BEGIN
    /*
    용도: 정책별 백업 명령과 제외 사유를 미리 봅니다. 파일은 만들지 않습니다.
    매개변수: @BackupType 백업 종류(기본 D); @DatabaseScope 대상 범위(기본 USER);
     @DatabaseName DB명(NULL이면 해당 범위 전체). 예시 GUID와 시작 시각은 실제 실행 시 새로 생성됩니다.
    코드: @BackupType D=전체, I=차등, L=로그; @DatabaseScope USER=사용자 DB, SYSTEM=시스템 DB.
    예제: EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseName=N'Sales';
          EXEC ops.usp_PreviewBackup @BackupType='L',@DatabaseScope='USER';
          EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseScope='SYSTEM';
    */
    SET NOCOUNT ON;
    IF @BackupType IS NULL OR @BackupType NOT IN ('D','I','L') OR @DatabaseScope IS NULL OR @DatabaseScope NOT IN ('USER','SYSTEM')
        THROW 51000,'Invalid backup type or scope.',1;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    DECLARE @db sysname,@item uniqueidentifier,@cmd nvarchar(max),@path nvarchar(1500),@reason nvarchar(2048);
    CREATE TABLE #preview(database_name sysname,item_id uniqueidentifier,command nvarchar(max),backup_path nvarchar(1500),exclusion_reason nvarchar(2048), example_started_at datetime2(3), preview_notice nvarchar(150));
    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR SELECT database_name FROM report.EffectiveBackupPolicy
        WHERE backup_type=@BackupType AND database_scope=@DatabaseScope AND (@DatabaseName IS NULL OR database_name=@DatabaseName);
    OPEN dbs; FETCH NEXT FROM dbs INTO @db;
    WHILE @@FETCH_STATUS=0
    BEGIN
        DECLARE @example_started_at datetime2(3)=SYSDATETIME();
        SET @item=NEWID();
        EXEC ops.usp_PlanBackup @db,@BackupType,@item,@cmd OUTPUT,@path OUTPUT,@reason OUTPUT,@example_started_at;
        INSERT #preview VALUES(@db,@item,@cmd,@path,@reason,@example_started_at,N'Example GUID and start time; regenerated for actual execution.');
        FETCH NEXT FROM dbs INTO @db;
    END;
    CLOSE dbs; DEALLOCATE dbs;
    IF @DatabaseName IS NOT NULL AND NOT EXISTS(SELECT 1 FROM #preview)
        THROW 51000,'Database not found in requested scope.',1;
    SELECT * FROM #preview ORDER BY database_name;
END;
GO
