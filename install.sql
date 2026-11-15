:On Error exit
:r sql/00-bootstrap.sql
:r sql/10-config.sql
:r sql/20-history.sql
:r sql/30-policy.sql
:r sql/40-backup.sql
:r sql/50-capacity.sql
:r sql/60-tools.sql
:r sql/70-agent.sql
USE DBADB;
GO
IF NOT EXISTS (SELECT 1 FROM cfg.SchemaVersion WHERE version = 2)
    INSERT cfg.SchemaVersion(version) VALUES (2);
IF NOT EXISTS (SELECT 1 FROM cfg.SchemaVersion WHERE version = 3)
    INSERT cfg.SchemaVersion(version) VALUES (3);
PRINT N'DBADB v3 installed. Configure paths, preview policies, then explicitly enable Agent jobs.';
GO
