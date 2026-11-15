:On Error exit
USE DBADB;
GO
IF (SELECT filename_pattern FROM cfg.BackupDefault WHERE database_scope='USER' AND backup_type='D')<>N'persist_[guid]'
    OR (SELECT filename_pattern FROM cfg.BackupOverride WHERE database_name=N'DBADB_IT_LS' AND backup_type='D')<>N'override_[guid]'
    THROW 52000,'Upgrade overwrote filename patterns.',1;
IF (SELECT retention_days FROM cfg.BackupDefault WHERE database_scope='USER' AND backup_type='D')<>31
    THROW 52000,'Upgrade overwrote default configuration.',1;
IF EXISTS(SELECT 1 FROM cfg.BackupOverride WHERE database_name=N'DBADB_IT_LS' AND note<>N'preserve on upgrade')
    THROW 52000,'Upgrade overwrote override.',1;
IF NOT EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id WHERE c.job_key='HISTORY' AND j.enabled=1)
    THROW 52000,'Upgrade reset job enabled state.',1;
IF NOT EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobschedules js ON js.job_id=c.job_id
    JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id WHERE c.job_key='HISTORY' AND s.freq_subday_interval=17)
    THROW 52000,'Upgrade reset job schedule.',1;
IF NOT EXISTS(SELECT 1 FROM report.BackupHistory WHERE database_name=N'DBADB_IT_Full' AND execution_source='PROJECT')
    THROW 52000,'Upgrade lost archived history.',1;
IF EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id
    LEFT JOIN msdb.dbo.sysoperators o ON o.id=j.notify_email_operator_id
    WHERE j.notify_level_email<>2 OR ISNULL(o.name,N'')<>N'DBADB_IT_Operator')
    THROW 52000,'Upgrade reset job notification.',1;
IF EXISTS(SELECT 1 FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id WHERE j.owner_sid<>SUSER_SID(N'DBADB_IT_Owner'))
    THROW 52000,'Upgrade reset job owner.',1;
IF (SELECT COUNT(*) FROM cfg.AgentJob)<>7
    OR (SELECT STRING_AGG(CONVERT(varchar(3),version),',') WITHIN GROUP (ORDER BY version) FROM cfg.SchemaVersion)<>'1,2,3'
    THROW 52000,'Deployment duplicated metadata.',1;
PRINT N'Reinstall and upgrade preservation assertions passed.';
GO
