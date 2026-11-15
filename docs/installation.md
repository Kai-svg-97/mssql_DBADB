# 설치 매뉴얼

SQL Server 2019 이상 Windows 인스턴스마다 DBADB를 설치합니다. 아래 경로와 DB 이름은 예시이므로 해당 서버에 맞게 바꿉니다. SQL 실행·설치 계정은 sysadmin이어야 하며 SQL Server Agent가 시작되어 있어야 합니다.

## 1. 사전 확인

```sql
SELECT @@SERVERNAME AS instance_name, SERVERPROPERTY('ProductVersion') AS product_version,
       IS_SRVROLEMEMBER(N'sysadmin') AS is_sysadmin;
SELECT servicename, status_desc, service_account FROM sys.dm_server_services;
SELECT name, state_desc, recovery_model_desc FROM sys.databases ORDER BY database_id;
```

백업 폴더는 SQL Server **데이터베이스 엔진 서비스 계정**이 쓰므로 서비스 계정을 확인합니다. Agent 계정과 다를 수 있습니다. 로컬 폴더 또는 UNC 공유를 미리 만들고 필요한 NTFS 및 공유 권한을 부여합니다. DBADB는 폴더를 생성하지 않습니다.

## 2. 신규 설치

Windows PowerShell에서 저장소 루트로 이동한 후 Windows 인증으로 실행합니다. 명명된 인스턴스 예시는 `-S 'HOST01\INSTANCE1'`입니다.

```powershell
cd C:\DBADB\mssql_DBADB
sqlcmd -S 'HOST01\INSTANCE1' -E -b -i install.sql
```

SSMS에서는 저장소 루트를 작업 디렉터리로 설정하고 **쿼리 > SQLCMD 모드**를 켠 후 `install.sql`을 실행합니다. `:r` 경로는 저장소 루트 기준입니다. 오류가 발생하면 메시지를 확인하고 원인을 해결한 뒤 재실행합니다.

```sql
USE DBADB;
SELECT * FROM cfg.SchemaVersion ORDER BY version;
SELECT c.job_key, j.name, j.enabled, SUSER_SNAME(j.owner_sid) AS owner_login
FROM cfg.AgentJob c JOIN msdb.dbo.sysjobs j ON j.job_id=c.job_id ORDER BY c.job_key;
```

새로 생성된 7개 작업은 모두 비활성입니다. 기존에 같은 이름의 외부 작업이 있으면 설치가 중단되므로 해당 작업을 조사하고 이름 충돌을 해결한 뒤 재실행합니다.

## 3. 유형별 경로 설정

### 로컬 디스크

예를 들어 `D:\SQLBackup\User`와 `D:\SQLBackup\System`을 만들고 엔진 서비스 계정에 쓰기 권한을 부여합니다.

```sql
USE DBADB;
UPDATE cfg.BackupDefault SET directory=N'D:\SQLBackup\User' WHERE database_scope='USER';
UPDATE cfg.BackupDefault SET directory=N'D:\SQLBackup\System' WHERE database_scope='SYSTEM';
SELECT * FROM report.EffectiveBackupPolicy ORDER BY database_name,backup_type;
```

### UNC 공유

예를 들어 `\\backup01\sqlbackup\instance1\user`와 `system` 공유 폴더를 준비하고 서비스 계정에 공유 및 NTFS 쓰기 권한을 모두 부여합니다. 매핑 드라이브는 서비스 세션에서 보이지 않을 수 있으므로 UNC를 사용합니다.

```sql
USE DBADB;
UPDATE cfg.BackupDefault SET directory=N'\\backup01\sqlbackup\instance1\user' WHERE database_scope='USER';
UPDATE cfg.BackupDefault SET directory=N'\\backup01\sqlbackup\instance1\system' WHERE database_scope='SYSTEM';
```

### DB와 백업 종류별 경로

```sql
USE DBADB;
-- 예외가 이미 있으면 INSERT 대신 해당 행을 UPDATE합니다.
INSERT cfg.BackupOverride(database_name,backup_type,directory,retention_days,note)
VALUES(N'Sales','D',N'E:\SalesBackup',30,N'전체 백업 별도 경로');
INSERT cfg.BackupOverride(database_name,backup_type,directory,retention_days)
VALUES(N'Sales','L',N'\\backup01\sqlbackup\instance1\sales-log',7);
SELECT * FROM report.EffectiveBackupPolicy WHERE database_name=N'Sales';
```

최종 파일 경로는 259자 이내여야 합니다. 빈 문자열은 경로 미설정이며 NULL 예외 값은 기본값 상속입니다.

## 4. 미리보기와 Agent 활성화

```sql
USE DBADB;
EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseScope='USER';
EXEC ops.usp_PreviewBackup @BackupType='L',@DatabaseScope='USER';
EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseScope='SYSTEM';
SELECT * FROM report.LogShippingStatus;
SELECT * FROM report.BackupSchedule ORDER BY database_name,backup_type;
```

명령·제외 이유·경로를 검토한 뒤 필요한 작업을 각각 활성화합니다. 전체, 로그, 시스템 전체, 이력 수집, 용량 수집을 선택하는 예시입니다. `USER_DIFFERENTIAL`은 차등 정책을 활성화한 경우 선택합니다. 상태 점검은 첫 백업이 끝난 뒤 활성화합니다.

```sql
USE DBADB;
DECLARE @key varchar(30), @job uniqueidentifier;
DECLARE jobs CURSOR LOCAL FAST_FORWARD FOR
SELECT job_key,job_id FROM cfg.AgentJob
WHERE job_key IN ('USER_FULL','USER_LOG','SYSTEM_FULL','HISTORY','CAPACITY');
OPEN jobs; FETCH NEXT FROM jobs INTO @key,@job;
WHILE @@FETCH_STATUS=0
BEGIN
    EXEC msdb.dbo.sp_update_job @job_id=@job,@enabled=1;
    FETCH NEXT FROM jobs INTO @key,@job;
END;
CLOSE jobs; DEALLOCATE jobs;
SELECT * FROM report.ProjectSchedules ORDER BY job_key;
```

정책 기본 시각은 사용자 전체 02:00, 시스템 전체 01:00, 사용자 로그 15분 간격입니다. 작업은 매분 정책을 점검합니다. 처음 활성화할 때 현재 슬롯을 처리할 수 있으므로 업무 시간 실행을 피하려면 활성화 전에 `catch_up_minutes`를 설정합니다.

## 5. 알림과 소유자

Database Mail과 활성 SQL Server Agent 운영자를 운영자가 먼저 준비하고 Agent 메일 프로필을 활성화합니다. 기존 작업에 알림을 지정하고 첫 백업 확인 후 상태 점검 작업을 활성화하는 예시입니다.

```sql
USE DBADB;
EXEC ops.usp_SetJobNotification @OperatorName=N'DBA Team';
DECLARE @job uniqueidentifier=(SELECT job_id FROM cfg.AgentJob WHERE job_key='HEALTH_CHECK');
EXEC msdb.dbo.sp_update_job @job_id=@job,@enabled=1;
SELECT job_key,job_enabled,notify_level_email,notify_email_operator FROM report.ProjectSchedules;
-- 필요 시 기존 sysadmin 로그인으로 작업 소유자 변경
EXEC ops.usp_SetJobOwner @LoginName=N'DOMAIN\SqlAgentOwner';
```

## 6. 재설치·업그레이드

DBADB 작업을 비활성화하고 실행이 끝났는지 `report.ProjectSchedules`에서 확인한 다음, DBADB 자체 백업을 포함한 기존 복구 절차를 준비합니다. 저장소 루트에서 다음을 실행합니다.

```powershell
sqlcmd -S 'HOST01\INSTANCE1' -E -b -i upgrade.sql
```

```sql
USE DBADB;
SELECT * FROM cfg.SchemaVersion ORDER BY version;
SELECT * FROM cfg.BackupDefault ORDER BY database_scope,backup_type;
SELECT * FROM cfg.BackupOverride ORDER BY database_name,backup_type;
SELECT * FROM report.ProjectSchedules ORDER BY job_key;
```

기존 설정·이력·작업 활성 상태·일정은 보존합니다. 업그레이드 전에 작업을 비활성화했다면 검토 후 필요한 작업을 다시 활성화합니다. 운영 상세 예제는 [운영 매뉴얼](operations.md)을 참고합니다.

## 배포 패키지 생성

개발 환경에서 저장소 루트의 다음 명령을 실행하면 설치 SQL과 매뉴얼을 포함한 ZIP이 `dist/`에 생성됩니다. Python 3 표준 라이브러리만 필요합니다.

```sh
python3 scripts/package.py
```

대상 서버에서 ZIP을 압축 해제한 디렉터리로 이동하여 위의 신규 설치 또는 업그레이드 `sqlcmd` 명령을 실행합니다. `sql/` 디렉터리 구조를 유지해야 `:r` 참조를 읽을 수 있습니다.
