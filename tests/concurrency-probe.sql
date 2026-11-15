:On Error exit
USE DBADB;
GO
DECLARE @r uniqueidentifier;
EXEC ops.usp_Backup @DatabaseName=N'DBADB_IT_Full',@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'ANOTHER_PROJECT_BACKUP_IS_RUNNING')
    THROW 52000,'Concurrent full backup was not blocked.',1;
EXEC ops.usp_Backup @BackupType='I',@DatabaseName=N'DBADB_IT_Full',@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SKIPPED' AND reason=N'ANOTHER_PROJECT_BACKUP_IS_RUNNING')
    THROW 52000,'Differential during a full was not blocked.',1;
-- The engine allows a log backup during a full/differential backup; DBADB must not block it.
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'DBADB_IT_Full',@RunId=@r OUTPUT;
IF NOT EXISTS(SELECT 1 FROM ops.BackupItem WHERE run_id=@r AND status='SUCCEEDED')
    THROW 52000,'Log backup was blocked by the full/differential lock.',1;
PRINT N'Concurrent session assertions passed.';
GO
