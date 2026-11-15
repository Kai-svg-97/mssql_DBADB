:On Error exit
USE DBADB;
GO
DECLARE @result int,@resource nvarchar(255)=N'DBADB:Backup:'+CONVERT(nvarchar(10),DB_ID(N'DBADB_IT_Full'));
EXEC @result=sys.sp_getapplock @Resource=@resource,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
IF @result<0 THROW 52000,'Test could not acquire backup lock.',1;
RAISERROR('DBADB_LOCK_READY',0,1) WITH NOWAIT;
UPDATE dbo.IT_LockSignal SET ready=1;
DECLARE @deadline datetime2=DATEADD(second,45,SYSDATETIME());
WHILE EXISTS(SELECT 1 FROM dbo.IT_LockSignal WHERE release_lock=0)
BEGIN
    IF SYSDATETIME()>@deadline THROW 52000,'Lock probe did not signal completion.',1;
    WAITFOR DELAY '00:00:00.100';
END;
EXEC sys.sp_releaseapplock @Resource=@resource,@LockOwner='Session';
GO
