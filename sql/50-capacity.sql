USE DBADB;
GO
IF OBJECT_ID(N'collect.CapacityDatabase', N'U') IS NULL
CREATE TABLE collect.CapacityDatabase (
    database_name sysname NOT NULL PRIMARY KEY,
    database_guid uniqueidentifier NULL,
    collected_at datetime2(0) NULL,
    last_attempt_at datetime2(0) NOT NULL,
    status varchar(12) NOT NULL,
    error_message nvarchar(2048) NULL,
    log_total_bytes bigint NULL,
    log_used_bytes bigint NULL,
    log_used_percent real NULL
);
IF OBJECT_ID(N'collect.CapacityFile', N'U') IS NULL
CREATE TABLE collect.CapacityFile (
    database_name sysname NOT NULL REFERENCES collect.CapacityDatabase(database_name),
    file_id int NOT NULL,
    logical_name sysname NOT NULL,
    physical_name nvarchar(260) NOT NULL,
    file_type nvarchar(60) NOT NULL,
    filegroup_name sysname NULL,
    allocated_pages bigint NOT NULL,
    used_pages bigint NULL,
    PRIMARY KEY(database_name,file_id)
);
IF OBJECT_ID(N'collect.CapacityTable', N'U') IS NULL
CREATE TABLE collect.CapacityTable (
    database_name sysname NOT NULL REFERENCES collect.CapacityDatabase(database_name),
    object_id int NOT NULL,
    schema_name sysname NOT NULL,
    table_name sysname NOT NULL,
    row_count bigint NOT NULL,
    reserved_pages bigint NOT NULL,
    used_pages bigint NOT NULL,
    data_pages bigint NOT NULL,
    index_pages bigint NOT NULL,
    PRIMARY KEY(database_name,object_id)
);
GO
CREATE OR ALTER PROCEDURE collect.usp_Capacity @DatabaseName sysname=NULL
AS
BEGIN
    /*
    용도: DB 파일, 테이블, 로그 용량을 수집합니다.
    매개변수: @DatabaseName DB명(NULL 또는 생략 시 전체). sysadmin으로 사용자 트랜잭션 밖에서 호출합니다.
    수집 상태 코드: RUNNING=진행, SUCCEEDED=성공, FAILED=실패, SKIPPED=지원하지 않는 상태로 제외.
    예제: EXEC collect.usp_Capacity @DatabaseName=N'Sales'; -- 한 DB
          EXEC collect.usp_Capacity; -- 전체 DB
          SELECT * FROM report.TableSpace WHERE database_name=N'Sales' ORDER BY reserved_mb DESC;
    */
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51000,'sysadmin is required.',1;
    IF @@TRANCOUNT<>0 THROW 51000,'Run collection outside a user transaction.',1;
    IF @DatabaseName IS NOT NULL AND DB_ID(@DatabaseName) IS NULL THROW 51000,'Database not found.',1;
    DECLARE @db sysname,@guid uniqueidentifier,@sql nvarchar(max),@lock int,@id bigint,@failed bit=0;
    EXEC @lock=sys.sp_getapplock @Resource=N'DBADB:Capacity',@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
    IF @lock<0 THROW 51001,'Another capacity collector is running.',1;
    INSERT collect.CollectionRun(collection_type,status) VALUES('CAPACITY','RUNNING');
    SET @id=SCOPE_IDENTITY();
    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR SELECT d.name,r.database_guid FROM sys.databases d
        LEFT JOIN sys.database_recovery_status r ON r.database_id=d.database_id
        WHERE d.source_database_id IS NULL AND (@DatabaseName IS NULL OR d.name=@DatabaseName);
    BEGIN TRY
        OPEN dbs; FETCH NEXT FROM dbs INTO @db,@guid;
        WHILE @@FETCH_STATUS=0
        BEGIN
            IF NOT EXISTS(SELECT 1 FROM collect.CapacityDatabase WHERE database_name=@db)
                INSERT collect.CapacityDatabase(database_name,last_attempt_at,status) VALUES(@db,SYSDATETIME(),'RUNNING');
            -- Unsupported states are expected, not failures: keep the last good snapshot, record
            -- why, and do not fail the job (a failing job on every AG instance hides real errors).
            IF EXISTS(SELECT 1 FROM sys.databases WHERE name=@db AND (state_desc<>'ONLINE' OR group_database_id IS NOT NULL OR is_in_standby=1))
            BEGIN
                UPDATE collect.CapacityDatabase SET last_attempt_at=SYSDATETIME(),status='SKIPPED',
                    error_message=N'Capacity collection requires an online, non-AG, non-standby database.' WHERE database_name=@db;
                FETCH NEXT FROM dbs INTO @db,@guid;
                CONTINUE;
            END;
            BEGIN TRY
                BEGIN TRANSACTION;
                DELETE collect.CapacityFile WHERE database_name=@db;
                DELETE collect.CapacityTable WHERE database_name=@db;
                SET @sql=N'USE '+QUOTENAME(@db)+N';
                    INSERT DBADB.collect.CapacityFile(database_name,file_id,logical_name,physical_name,file_type,filegroup_name,allocated_pages,used_pages)
                    SELECT @db,f.file_id,f.name,f.physical_name,f.type_desc,g.name,CONVERT(bigint,f.size),
                        CASE WHEN f.type=0 THEN CONVERT(bigint,FILEPROPERTY(f.name,''SpaceUsed'')) END
                    FROM sys.database_files f LEFT JOIN sys.filegroups g ON g.data_space_id=f.data_space_id;
                    INSERT DBADB.collect.CapacityTable(database_name,object_id,schema_name,table_name,row_count,reserved_pages,used_pages,data_pages,index_pages)
                    SELECT @db,t.object_id,s.name,t.name,
                        SUM(CASE WHEN p.index_id IN (0,1) THEN p.row_count ELSE 0 END),
                        SUM(p.reserved_page_count),SUM(p.used_page_count),
                        SUM(CASE WHEN p.index_id IN (0,1) THEN p.in_row_data_page_count+p.lob_used_page_count+p.row_overflow_used_page_count ELSE 0 END),
                        SUM(p.used_page_count)-SUM(CASE WHEN p.index_id IN (0,1) THEN p.in_row_data_page_count+p.lob_used_page_count+p.row_overflow_used_page_count ELSE 0 END)
                    FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
                    JOIN sys.dm_db_partition_stats p ON p.object_id=t.object_id
                    WHERE t.is_ms_shipped=0 AND t.is_memory_optimized=0
                    GROUP BY t.object_id,s.name,t.name;
                    UPDATE DBADB.collect.CapacityDatabase SET log_total_bytes=l.total_log_size_in_bytes,
                        log_used_bytes=l.used_log_space_in_bytes,log_used_percent=l.used_log_space_in_percent
                    FROM sys.dm_db_log_space_usage l WHERE database_name=@db;';
                EXEC sys.sp_executesql @sql,N'@db sysname',@db;
                UPDATE collect.CapacityDatabase SET database_guid=@guid,collected_at=SYSDATETIME(),
                    last_attempt_at=SYSDATETIME(),status='SUCCEEDED',error_message=NULL WHERE database_name=@db;
                COMMIT;
            END TRY
            BEGIN CATCH
                IF XACT_STATE()<>0 ROLLBACK;
                SET @failed=1;
                UPDATE collect.CapacityDatabase SET last_attempt_at=SYSDATETIME(),status='FAILED',error_message=ERROR_MESSAGE() WHERE database_name=@db;
            END CATCH;
            FETCH NEXT FROM dbs INTO @db,@guid;
        END;
        CLOSE dbs; DEALLOCATE dbs;
        UPDATE collect.CollectionRun SET status=CASE WHEN @failed=1 THEN 'PARTIAL' ELSE 'SUCCEEDED' END,finished_at=SYSDATETIME() WHERE collection_id=@id;
        EXEC sys.sp_releaseapplock @Resource=N'DBADB:Capacity',@LockOwner='Session';
    END TRY
    BEGIN CATCH
        IF XACT_STATE()<>0 ROLLBACK;
        IF CURSOR_STATUS('local','dbs')>=0 CLOSE dbs;
        IF CURSOR_STATUS('local','dbs')>-3 DEALLOCATE dbs;
        EXEC sys.sp_releaseapplock @Resource=N'DBADB:Capacity',@LockOwner='Session';
        UPDATE collect.CollectionRun SET status='FAILED',finished_at=SYSDATETIME(),error_message=ERROR_MESSAGE() WHERE collection_id=@id;
        THROW;
    END CATCH;
    IF @failed=1 THROW 51003,'Some capacity collections failed. Query collect.CapacityDatabase.',1;
END;
GO
CREATE OR ALTER VIEW report.FileSpace AS
SELECT f.*,f.allocated_pages/128.0 AS allocated_mb,f.used_pages/128.0 AS used_mb,
    (f.allocated_pages-f.used_pages)/128.0 AS free_mb,
    d.collected_at,d.last_attempt_at,d.status AS collection_status,d.error_message,
    CAST(CASE WHEN DB_ID(f.database_name) IS NULL OR NOT EXISTS(SELECT 1 FROM sys.database_recovery_status r
        WHERE r.database_id=DB_ID(f.database_name) AND r.database_guid=d.database_guid) THEN 1 ELSE 0 END AS bit) AS database_identity_changed
FROM collect.CapacityFile f JOIN collect.CapacityDatabase d ON d.database_name=f.database_name;
GO
CREATE OR ALTER VIEW report.FilegroupSpace AS
SELECT database_name,filegroup_name,SUM(allocated_pages)/128.0 AS allocated_mb,
    SUM(used_pages)/128.0 AS used_mb,SUM(allocated_pages-used_pages)/128.0 AS free_mb,
    collected_at,last_attempt_at,collection_status,error_message,database_identity_changed
FROM report.FileSpace WHERE file_type='ROWS'
GROUP BY database_name,filegroup_name,collected_at,last_attempt_at,collection_status,error_message,database_identity_changed;
GO
CREATE OR ALTER VIEW report.TableSpace AS
SELECT t.*,t.reserved_pages/128.0 AS reserved_mb,t.used_pages/128.0 AS used_mb,
    t.data_pages/128.0 AS data_mb,t.index_pages/128.0 AS index_mb,
    (t.reserved_pages-t.used_pages)/128.0 AS unused_reserved_mb,
    d.collected_at,d.last_attempt_at,d.status AS collection_status,d.error_message
FROM collect.CapacityTable t JOIN collect.CapacityDatabase d ON d.database_name=t.database_name;
GO
CREATE OR ALTER VIEW report.LogSpace AS
SELECT database_name,database_guid,log_total_bytes/1048576.0 AS total_mb,log_used_bytes/1048576.0 AS used_mb,
    (log_total_bytes-log_used_bytes)/1048576.0 AS free_mb,log_used_percent,collected_at,last_attempt_at,status AS collection_status,error_message
FROM collect.CapacityDatabase;
GO
