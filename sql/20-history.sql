USE DBADB;
GO
IF OBJECT_ID(N'collect.BackupHistory', N'U') IS NULL
CREATE TABLE collect.BackupHistory (
    backup_set_uuid uniqueidentifier NOT NULL PRIMARY KEY,
    source_backup_set_id int NOT NULL,
    database_name sysname NULL,
    database_guid uniqueidentifier NULL,
    backup_type char(1) NULL,
    backup_start_date datetime NULL,
    backup_finish_date datetime NULL,
    backup_size numeric(20,0) NULL,
    compressed_backup_size numeric(20,0) NULL,
    user_name nvarchar(128) NULL,
    server_name nvarchar(128) NULL,
    backup_name nvarchar(128) NULL,
    is_copy_only bit NULL,
    first_lsn numeric(25,0) NULL,
    last_lsn numeric(25,0) NULL,
    database_backup_lsn numeric(25,0) NULL,
    collected_at datetime2(0) NOT NULL DEFAULT SYSDATETIME()
);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'collect.BackupHistory') AND name=N'IX_BackupHistory_Database')
CREATE INDEX IX_BackupHistory_Database ON collect.BackupHistory(database_name,backup_type,backup_finish_date DESC)
    INCLUDE(database_guid,is_copy_only);
IF OBJECT_ID(N'collect.BackupMedia', N'U') IS NULL
CREATE TABLE collect.BackupMedia (
    backup_set_uuid uniqueidentifier NOT NULL REFERENCES collect.BackupHistory(backup_set_uuid),
    family_sequence_number tinyint NOT NULL,
    mirror tinyint NOT NULL,
    physical_device_name nvarchar(260) NULL,
    device_type tinyint NULL,
    PRIMARY KEY(backup_set_uuid, family_sequence_number, mirror)
);
IF OBJECT_ID(N'collect.CollectionRun', N'U') IS NULL
CREATE TABLE collect.CollectionRun (
    collection_id bigint IDENTITY NOT NULL PRIMARY KEY,
    collection_type varchar(20) NOT NULL,
    started_at datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    finished_at datetime2(3) NULL,
    status varchar(12) NOT NULL,
    rows_inserted int NULL,
    error_message nvarchar(2048) NULL
);
GO
CREATE OR ALTER VIEW report.BackupHistory
AS
WITH source_rows AS (
    SELECT b.*,ROW_NUMBER() OVER(PARTITION BY b.backup_set_uuid ORDER BY b.backup_set_id DESC) AS uuid_row
    FROM msdb.dbo.backupset b WHERE b.backup_set_uuid IS NOT NULL AND b.backup_finish_date IS NOT NULL
), h AS (
    SELECT backup_set_uuid, source_backup_set_id, database_name, database_guid, backup_type,
        backup_start_date, backup_finish_date, backup_size, compressed_backup_size, user_name,
        server_name, backup_name, is_copy_only, first_lsn, last_lsn, database_backup_lsn, collected_at
    FROM collect.BackupHistory WITH (HOLDLOCK)
    UNION ALL
    SELECT b.backup_set_uuid,b.backup_set_id,b.database_name,b.database_guid,b.type,
        b.backup_start_date,b.backup_finish_date,b.backup_size,b.compressed_backup_size,b.user_name,
        b.server_name,b.name,b.is_copy_only,b.first_lsn,b.last_lsn,b.database_backup_lsn,CAST(NULL AS datetime2(0))
    FROM source_rows b WHERE b.uuid_row=1
      AND NOT EXISTS (SELECT 1 FROM collect.BackupHistory a WITH (HOLDLOCK) WHERE a.backup_set_uuid=b.backup_set_uuid)
)
SELECT h.*, i.run_id, i.item_id,
    CASE WHEN i.item_id IS NOT NULL THEN 'PROJECT' ELSE 'UNATTRIBUTED' END AS execution_source
FROM h LEFT JOIN ops.BackupItem i ON i.backup_name=h.backup_name
    AND i.database_name=h.database_name AND i.backup_type=h.backup_type;
GO
CREATE OR ALTER VIEW report.BackupMedia
AS
WITH source_rows AS (
    SELECT b.backup_set_uuid,b.media_set_id,
        ROW_NUMBER() OVER(PARTITION BY b.backup_set_uuid ORDER BY b.backup_set_id DESC) AS uuid_row
    FROM msdb.dbo.backupset b WHERE b.backup_set_uuid IS NOT NULL AND b.backup_finish_date IS NOT NULL
)
SELECT backup_set_uuid,family_sequence_number,mirror,physical_device_name,device_type
FROM collect.BackupMedia WITH (HOLDLOCK)
UNION ALL
SELECT DISTINCT b.backup_set_uuid,m.family_sequence_number,m.mirror,m.physical_device_name,m.device_type
FROM source_rows b JOIN msdb.dbo.backupmediafamily m ON m.media_set_id=b.media_set_id
WHERE b.uuid_row=1
  AND NOT EXISTS (SELECT 1 FROM collect.BackupMedia a WITH (HOLDLOCK) WHERE a.backup_set_uuid=b.backup_set_uuid
    AND a.family_sequence_number=m.family_sequence_number AND a.mirror=m.mirror);
GO
CREATE OR ALTER PROCEDURE collect.usp_BackupHistory
AS
BEGIN
    /*
    용도: msdb 백업 이력과 미디어 정보를 DBADB에 수집합니다. 매개변수는 없습니다.
    반복 수집은 백업 세트 UUID를 기준으로 중복을 방지합니다. sysadmin으로 사용자 트랜잭션 밖에서 호출합니다.
    예제: EXEC collect.usp_BackupHistory; -- 즉시 수집
          SELECT TOP (20) * FROM report.BackupHistory ORDER BY backup_finish_date DESC; -- 수집 결과 확인
    */
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    IF @@TRANCOUNT<>0 THROW 51000,'Run collection outside a user transaction.',1;
    DECLARE @id bigint, @lock int, @rows int;
    INSERT collect.CollectionRun(collection_type,status) VALUES ('BACKUP_HISTORY','RUNNING');
    SET @id=SCOPE_IDENTITY();
    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC @lock=sys.sp_getapplock @Resource=N'DBADB:History',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
        IF @lock<0 THROW 51001,'Another history collector is running.',1;
        -- No high-water mark: catches long-running backups, imported history and msdb identity
        -- resets. Only unseen UUIDs are inserted. msdb is read without range locks so backups can
        -- keep writing their history; rows committed meanwhile are picked up by the next run.
        ;WITH source_rows AS (
            SELECT b.*,ROW_NUMBER() OVER(PARTITION BY b.backup_set_uuid ORDER BY b.backup_set_id DESC) AS uuid_row
            FROM msdb.dbo.backupset b
            WHERE b.backup_set_uuid IS NOT NULL AND b.backup_finish_date IS NOT NULL
        )
        SELECT b.backup_set_uuid,b.backup_set_id,b.database_name,b.database_guid,b.type,
            b.backup_start_date,b.backup_finish_date,b.backup_size,b.compressed_backup_size,b.user_name,
            b.server_name,b.name,b.is_copy_only,b.first_lsn,b.last_lsn,b.database_backup_lsn,b.media_set_id
        INTO #new FROM source_rows b
        WHERE b.uuid_row=1
          AND NOT EXISTS(SELECT 1 FROM collect.BackupHistory a WHERE a.backup_set_uuid=b.backup_set_uuid);
        INSERT collect.BackupHistory(backup_set_uuid,source_backup_set_id,database_name,database_guid,backup_type,
            backup_start_date,backup_finish_date,backup_size,compressed_backup_size,user_name,server_name,
            backup_name,is_copy_only,first_lsn,last_lsn,database_backup_lsn)
        SELECT backup_set_uuid,backup_set_id,database_name,database_guid,type,
            backup_start_date,backup_finish_date,backup_size,compressed_backup_size,user_name,server_name,
            name,is_copy_only,first_lsn,last_lsn,database_backup_lsn FROM #new;
        SET @rows=@@ROWCOUNT;
        -- Also repair missing media rows on a later collection if source media became available later.
        ;WITH source_rows AS (
            SELECT b.backup_set_uuid,b.media_set_id,
                ROW_NUMBER() OVER(PARTITION BY b.backup_set_uuid ORDER BY b.backup_set_id DESC) AS uuid_row
            FROM msdb.dbo.backupset b WHERE b.backup_set_uuid IS NOT NULL AND b.backup_finish_date IS NOT NULL
        )
        INSERT collect.BackupMedia(backup_set_uuid,family_sequence_number,mirror,physical_device_name,device_type)
        SELECT DISTINCT b.backup_set_uuid,m.family_sequence_number,m.mirror,m.physical_device_name,m.device_type
        FROM source_rows b JOIN msdb.dbo.backupmediafamily m ON b.media_set_id=m.media_set_id
        JOIN collect.BackupHistory h ON h.backup_set_uuid=b.backup_set_uuid
        WHERE b.uuid_row=1 AND NOT EXISTS(SELECT 1 FROM collect.BackupMedia a WHERE a.backup_set_uuid=b.backup_set_uuid
            AND a.family_sequence_number=m.family_sequence_number AND a.mirror=m.mirror);
        UPDATE i SET backup_set_uuid=h.backup_set_uuid
        FROM ops.BackupItem i JOIN collect.BackupHistory h ON i.backup_name=h.backup_name
            AND i.database_name=h.database_name AND i.backup_type=h.backup_type
        WHERE i.backup_set_uuid IS NULL;
        COMMIT;
        UPDATE collect.CollectionRun SET status='SUCCEEDED',finished_at=SYSDATETIME(),rows_inserted=@rows WHERE collection_id=@id;
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        UPDATE collect.CollectionRun SET status='FAILED',finished_at=SYSDATETIME(),error_message=ERROR_MESSAGE() WHERE collection_id=@id;
        THROW;
    END CATCH
END;
GO
