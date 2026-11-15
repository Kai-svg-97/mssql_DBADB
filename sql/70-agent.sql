USE DBADB;
GO
CREATE OR ALTER PROCEDURE ops.usp_InstallAgentJobs
AS
BEGIN
    /*
    용도: 누락된 DBADB Agent 작업을 생성하고 기존 작업 단계를 갱신합니다. 매개변수는 없습니다.
    신규 작업은 비활성으로 생성되며 기존 활성 상태·소유자·일정은 유지됩니다. 사용자 트랜잭션 밖에서 호출합니다.
    예제: EXEC ops.usp_InstallAgentJobs; -- 설치 또는 재설치
          SELECT * FROM report.ProjectSchedules ORDER BY job_key; -- 설치 결과 확인
    */
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    IF @@TRANCOUNT<>0 THROW 51000,'Run job installation outside a user transaction.',1;
    DECLARE @key varchar(30),@name sysname,@command nvarchar(max),@job uniqueidentifier,
        -- New jobs are owned by the built-in sa login (SID 0x01), which survives staff changes and
        -- still owns jobs when disabled. Existing jobs keep their owner; see ops.usp_SetJobOwner.
        @owner sysname=COALESCE(SUSER_SNAME(0x01),ORIGINAL_LOGIN()),@frequency int,@subtype int,@lock int;
    DECLARE jobs CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM (VALUES
        ('USER_FULL',N'DBADB - User full',N'EXEC ops.usp_Backup @BackupType=''D'',@DatabaseScope=''USER'',@RespectSchedule=1;',4,1),
        ('USER_DIFFERENTIAL',N'DBADB - User differential',N'EXEC ops.usp_Backup @BackupType=''I'',@DatabaseScope=''USER'',@RespectSchedule=1;',4,1),
        ('USER_LOG',N'DBADB - User log',N'EXEC ops.usp_Backup @BackupType=''L'',@DatabaseScope=''USER'',@RespectSchedule=1;',4,1),
        ('SYSTEM_FULL',N'DBADB - System full',N'EXEC ops.usp_Backup @BackupType=''D'',@DatabaseScope=''SYSTEM'',@RespectSchedule=1;',4,1),
        ('HISTORY',N'DBADB - Collect history',N'EXEC collect.usp_BackupHistory;',4,15),
        ('CAPACITY',N'DBADB - Collect capacity',N'EXEC collect.usp_Capacity;',8,1),
        ('HEALTH_CHECK',N'DBADB - Backup health check',N'EXEC ops.usp_CheckBackupHealth;',8,1)
    ) s(job_key,job_name,command,subtype,frequency);
    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC @lock=sys.sp_getapplock @Resource=N'DBADB:DeployJobs',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
        IF @lock<0 THROW 51001,'Another job deployment is running.',1;
        OPEN jobs; FETCH NEXT FROM jobs INTO @key,@name,@command,@subtype,@frequency;
        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @job=NULL;
            SELECT @job=job_id FROM cfg.AgentJob WHERE job_key=@key;
            IF @job IS NOT NULL AND NOT EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE job_id=@job)
            BEGIN
                DELETE cfg.AgentJob WHERE job_key=@key;
                SET @job=NULL;
            END;
            IF @job IS NULL
            BEGIN
                IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@name)
                    THROW 51000,'A job name is already in use outside the DBADB registry. Rename it before deployment.',1;
                EXEC msdb.dbo.sp_add_job @job_name=@name,@enabled=0,@owner_login_name=@owner,
                    @description=N'DBADB managed job. Backup ticks evaluate cfg policies in server local time.',@job_id=@job OUTPUT;
                EXEC msdb.dbo.sp_add_jobstep @job_id=@job,@step_name=N'DBADB',@subsystem=N'TSQL',
                    @database_name=N'DBADB',@command=@command,@on_success_action=1,@on_fail_action=2;
                EXEC msdb.dbo.sp_add_jobschedule @job_id=@job,@name=@name,@enabled=1,@freq_type=4,@freq_interval=1,
                    @freq_subday_type=@subtype,@freq_subday_interval=@frequency,@active_start_time=0,@active_start_date=20000101;
                EXEC msdb.dbo.sp_add_jobserver @job_id=@job;
                INSERT cfg.AgentJob(job_key,job_id) VALUES(@key,@job);
            END
            ELSE
                EXEC msdb.dbo.sp_update_jobstep @job_id=@job,@step_id=1,@database_name=N'DBADB',@command=@command;
            FETCH NEXT FROM jobs INTO @key,@name,@command,@subtype,@frequency;
        END;
        CLOSE jobs; DEALLOCATE jobs;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        IF CURSOR_STATUS('local','jobs')>=0 CLOSE jobs;
        IF CURSOR_STATUS('local','jobs')>-3 DEALLOCATE jobs;
        THROW;
    END CATCH
END;
GO
CREATE OR ALTER PROCEDURE ops.usp_SetJobNotification @OperatorName sysname=NULL
AS
BEGIN
    /*
    용도: DBADB 관리 작업 전체의 실패 이메일 알림을 설정하거나 해제합니다.
    매개변수: @OperatorName 활성 Agent 운영자명(NULL이면 해제). Database Mail과 운영자는 미리 구성합니다.
    알림 코드: 0=이메일 알림 해제, 2=작업 실패 시 이메일. 사용자 트랜잭션 밖에서 호출합니다.
    예제: EXEC ops.usp_SetJobNotification @OperatorName=N'DBA'; -- 실패 알림 설정
          EXEC ops.usp_SetJobNotification @OperatorName=NULL; -- 알림 해제
    */
    SET NOCOUNT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    IF @@TRANCOUNT<>0 THROW 51000,'Run notification changes outside a user transaction.',1;
    -- Uses an existing operator only; DBADB never creates operators or configures Database Mail.
    IF @OperatorName IS NOT NULL AND NOT EXISTS(SELECT 1 FROM msdb.dbo.sysoperators WHERE name=@OperatorName AND enabled=1)
        THROW 51000,'Enabled SQL Server Agent operator not found. Create the operator and Database Mail first.',1;
    DECLARE @job uniqueidentifier;
    DECLARE jobs CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.job_id FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id;
    OPEN jobs; FETCH NEXT FROM jobs INTO @job;
    WHILE @@FETCH_STATUS=0
    BEGIN
        IF @OperatorName IS NULL
            EXEC msdb.dbo.sp_update_job @job_id=@job,@notify_level_email=0,@notify_email_operator_name=N'';
        ELSE
            EXEC msdb.dbo.sp_update_job @job_id=@job,@notify_level_email=2,@notify_email_operator_name=@OperatorName;
        FETCH NEXT FROM jobs INTO @job;
    END;
    CLOSE jobs; DEALLOCATE jobs;
    SELECT job_key,job_name,notify_level_email,notify_email_operator FROM report.ProjectSchedules ORDER BY job_key;
END;
GO
CREATE OR ALTER PROCEDURE ops.usp_SetJobOwner @LoginName sysname
AS
BEGIN
    /*
    용도: DBADB 관리 작업 전체의 소유자를 변경합니다.
    매개변수: @LoginName 존재하는 sysadmin 로그인명. 사용자 트랜잭션 밖에서 호출합니다.
    예제: EXEC ops.usp_SetJobOwner @LoginName=N'sa'; -- 기본 제공 sa 로그인
          EXEC ops.usp_SetJobOwner @LoginName=N'DBADB_JobOwner'; -- 미리 생성한 sysadmin 로그인
    */
    SET NOCOUNT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    IF @@TRANCOUNT<>0 THROW 51000,'Run owner changes outside a user transaction.',1;
    -- A non-sysadmin owner would run the steps in its own context, where every DBADB procedure refuses.
    IF @LoginName IS NULL OR SUSER_SID(@LoginName) IS NULL OR ISNULL(IS_SRVROLEMEMBER(N'sysadmin',@LoginName),0)<>1
        THROW 51000,'Job owner must be an existing sysadmin login.',1;
    DECLARE @job uniqueidentifier;
    DECLARE jobs CURSOR LOCAL FAST_FORWARD FOR
        SELECT c.job_id FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id;
    OPEN jobs; FETCH NEXT FROM jobs INTO @job;
    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC msdb.dbo.sp_update_job @job_id=@job,@owner_login_name=@LoginName;
        FETCH NEXT FROM jobs INTO @job;
    END;
    CLOSE jobs; DEALLOCATE jobs;
    SELECT c.job_key,j.name AS job_name,SUSER_SNAME(j.owner_sid) AS owner_login
    FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id ORDER BY c.job_key;
END;
GO
EXEC ops.usp_InstallAgentJobs;
GO
