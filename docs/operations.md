# 운영·실환경 검증

설치와 경로 준비는 [설치 매뉴얼](installation.md)을 먼저 확인합니다. 아래 예제는 `sysadmin`으로 실행하며 DB 이름과 경로를 실제 값으로 바꿉니다. `cfg.BackupOverride`의 기본 키는 DB 이름과 백업 종류이므로 같은 행이 이미 있으면 INSERT 대신 UPDATE합니다.

## 일상 점검

```sql
USE DBADB;
SELECT * FROM report.BackupHealth WHERE health_status<>'OK' ORDER BY database_name,backup_type;
SELECT * FROM report.ProjectSchedules ORDER BY job_key;
SELECT TOP(100) * FROM ops.BackupRun ORDER BY started_at DESC;
SELECT TOP(100) database_name,backup_type,status,reason,started_at,finished_at,run_id
FROM ops.BackupItem WHERE status IN ('FAILED','SKIPPED') ORDER BY started_at DESC;
SELECT TOP(50) * FROM collect.CollectionRun ORDER BY started_at DESC;
```

`FAILED`는 백업 오류, `SKIPPED`는 사유가 있는 제외입니다. 예약 실행의 일반적인 제외는 일정 슬롯당 한 번 기록합니다. 오프라인·DB 식별자 변경은 일시적인 제외로 취급해 같은 슬롯에서도 다시 기록할 수 있습니다. 이전 시도와 DB GUID가 같으면 재시도 간격과 횟수를 적용합니다. 오프라인 중 GUID를 읽지 못하다가 온라인 후 확인되면 별도 식별자로 판단하여 다음 점검에서 실행될 수 있습니다. 실패 이력과 현재 상태는 별개이므로 복구 후 두 항목을 함께 확인합니다.

## 유형별 정책 예제

### 특정 DB만 로그 백업 제외

```sql
USE DBADB;
INSERT cfg.BackupOverride(database_name,backup_type,enabled,note)
VALUES(N'Scratch','L',0,N'운영자가 로그 백업 제외');
SELECT * FROM report.EffectiveBackupPolicy WHERE database_name=N'Scratch' ORDER BY backup_type;
-- 상속으로 되돌리려면 해당 예외를 삭제합니다.
-- DELETE cfg.BackupOverride WHERE database_name=N'Scratch' AND backup_type='L';
```

모든 백업을 제외하려면 `D`, `I`, `L` 각각에 `enabled=0`을 설정합니다. SIMPLE 복구 모델은 로그 백업이 제외되며 복구 모델을 자동 변경하지 않습니다.

### 차등 활성화 및 주간 전체

```sql
USE DBADB;
UPDATE cfg.BackupDefault SET enabled=1,start_time='14:00',interval_minutes=1440
WHERE database_scope='USER' AND backup_type='I';
INSERT cfg.BackupOverride(database_name,backup_type,interval_minutes,start_time,anchor_date,catch_up_minutes)
VALUES(N'Archive','D',10080,'02:00','20000102',180); -- 일요일 02:00, 3시간 허용
EXEC ops.usp_PreviewBackup @BackupType='I',@DatabaseName=N'Archive';
SELECT * FROM report.BackupSchedule WHERE database_name=N'Archive';
```

차등은 정상 전체 백업 기준이 필요합니다. 로그 시핑 기본 DB의 DBADB 전체는 COPY_ONLY이므로 새 차등 기준을 만들지 않습니다. 차등 정책을 켠 뒤 `USER_DIFFERENTIAL` Agent 작업도 활성화해야 합니다.

### 재시도·지연 실행 제한

```sql
USE DBADB;
UPDATE cfg.BackupDefault SET retry_count=2,retry_interval_minutes=15,catch_up_minutes=180
WHERE database_scope='USER' AND backup_type='D';
-- 기존 예외 행이 있다면 필요한 열만 UPDATE합니다.
UPDATE cfg.BackupOverride SET retry_count=3,retry_interval_minutes=10
WHERE database_name=N'Archive' AND backup_type='D';
SELECT database_name,backup_type,interval_minutes,start_time,anchor_date,
       catch_up_minutes,retry_count,retry_interval_minutes,current_slot_at,next_policy_slot_at
FROM report.BackupSchedule WHERE database_name=N'Archive';
```

재시도 횟수는 최초 시도에 추가되는 횟수입니다. `catch_up_minutes=0`은 지연 제한이 없고, 양수는 슬롯 시작 후 최초 시도와 재시도가 시작될 수 있는 시간을 제한합니다. 수동 실행은 시간 제한을 적용하지 않지만 제외·로그 시핑 보호는 적용합니다.

## 백업 경로와 파일명 예제

`Sales` DB의 전체·차등은 로컬 디스크에, 로그는 UNC 공유에 저장하는 예시입니다. 각 폴더를 미리 만들고 SQL Server 데이터베이스 엔진 서비스 계정에 쓰기 권한을 부여합니다. 예외 행이 이미 있으면 INSERT 대신 UPDATE합니다.

```sql
USE DBADB;
INSERT cfg.BackupOverride(database_name,backup_type,enabled,directory)
VALUES(N'Sales','D',1,N'E:\SalesBackup'),
      (N'Sales','I',1,N'E:\SalesBackup'),
      (N'Sales','L',1,N'\\backup01\sqlbackup\sales-log');

SELECT database_name,backup_type,enabled,directory,exclusion_reason
FROM report.EffectiveBackupPolicy WHERE database_name=N'Sales';
EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseName=N'Sales';
EXEC ops.usp_PreviewBackup @BackupType='I',@DatabaseName=N'Sales';
EXEC ops.usp_PreviewBackup @BackupType='L',@DatabaseName=N'Sales';
```

기본 패턴을 변경하지 않았다면 실제 백업 시 설정된 디렉터리 바로 아래에 다음 형식의 파일이 생성됩니다. DB ID가 `7`인 경우의 예시이며, 실제 ID와 GUID는 환경과 실행마다 다릅니다.

| 종류 | 패턴 | 생성 경로 예시 |
|---|---|---|
| 전체 (`D`) | `<DB명>_<DB ID>_<시도 GUID>.bak` | `E:\SalesBackup\Sales_7_0123456789abcdef0123456789abcdef.bak` |
| 차등 (`I`) | `<DB명>_<DB ID>_<시도 GUID>.bak` | `E:\SalesBackup\Sales_7_1123456789abcdef0123456789abcdef.bak` |
| 로그 (`L`) | `<DB명>_<DB ID>_<시도 GUID>.trn` | `\\backup01\sqlbackup\sales-log\Sales_7_2123456789abcdef0123456789abcdef.trn` |

DB명은 `\ / : * ? " < > |`를 `_`로 치환한 뒤 앞 80자까지 사용합니다. DB ID는 SQL Server의 데이터베이스 ID이며, GUID는 각 백업 시도에 생성된 값에서 하이픈을 제거한 32자리입니다. 재시도에도 새 GUID를 사용합니다. 기본 패턴에는 백업 시각이 없고 전체와 차등 모두 `.bak`을 사용합니다. 패턴에 시각을 추가할 수 있으며, 백업 종류와 정확한 시각은 이력에서 확인합니다. 차등은 유효한 전체 백업 기준이 필요하며 로그 시핑 기본 DB의 DBADB 로그 백업은 제외됩니다.

미리보기는 파일을 생성하지 않으며, 미리보기용 GUID를 새로 만들기 때문에 표시된 파일명은 실제 실행 파일명과 다릅니다. 실제 시도 경로와 백업 종류·시각은 다음에서 조회합니다.

```sql
USE DBADB;
SELECT TOP(100) database_name,backup_type,status,reason,backup_path,started_at,finished_at
FROM ops.BackupItem WHERE database_name=N'Sales' ORDER BY started_at DESC;

SELECT TOP(100) h.database_name,h.backup_type,h.backup_start_date,h.backup_finish_date,
       h.execution_source,m.physical_device_name
FROM report.BackupHistory h
LEFT JOIN report.BackupMedia m ON m.backup_set_uuid=h.backup_set_uuid
WHERE h.database_name=N'Sales' ORDER BY h.backup_finish_date DESC;
```

## 실행·이력 예제

```sql
USE DBADB;
EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseName=N'Sales';
EXEC ops.usp_Backup @BackupType='D',@DatabaseName=N'Sales';
EXEC ops.usp_Backup @BackupType='I',@DatabaseName=N'Sales';
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'Sales';
EXEC ops.usp_Backup @BackupType='D',@DatabaseScope='SYSTEM';
SELECT TOP(100) run_id,database_name,backup_type,status,reason,backup_path,started_at,finished_at
FROM ops.BackupItem ORDER BY started_at DESC;
EXEC collect.usp_BackupHistory;
SELECT TOP(100) h.database_name,h.backup_type,h.backup_start_date,h.backup_finish_date,
       h.backup_size,h.compressed_backup_size,h.user_name,h.execution_source,h.run_id,m.physical_device_name
FROM report.BackupHistory h LEFT JOIN report.BackupMedia m ON m.backup_set_uuid=h.backup_set_uuid
ORDER BY h.backup_finish_date DESC;
```

백업이 부분 실패하면 나머지 DB 처리를 마친 뒤 오류 51002를 반환합니다. 오류 메시지의 실행 ID로 `ops.BackupItem`을 조회합니다. 수동·외부 백업은 출처를 추정하지 않아 `UNATTRIBUTED`로 표시됩니다. 스트라이프·미러는 경로마다 행이 생기므로 크기를 조인 결과에서 단순 합산하지 않습니다.

## 용량·보존·블로킹 예제

```sql
USE DBADB;
EXEC collect.usp_Capacity @DatabaseName=N'Sales'; -- 생략하면 전체 DB
SELECT * FROM collect.CapacityDatabase ORDER BY database_name;
SELECT * FROM report.FileSpace WHERE database_name=N'Sales';
SELECT * FROM report.FilegroupSpace WHERE database_name=N'Sales';
SELECT * FROM report.TableSpace WHERE database_name=N'Sales' ORDER BY reserved_mb DESC;
SELECT * FROM report.LogSpace WHERE database_name=N'Sales';
SELECT * FROM report.DiskSpace ORDER BY free_percent;
SELECT * FROM report.ActiveRequests WHERE blocking_session_id<>0 ORDER BY total_elapsed_time DESC;
SELECT * FROM report.RetentionCandidates ORDER BY backup_finish_date;
```

용량 뷰의 수집 상태와 시각을 함께 확인합니다. 디스크 뷰는 DB 파일이 있는 볼륨 기준으로, 별도의 백업 공유 공간을 보장하지 않습니다. 보존 후보는 검토 목록이며 파일 존재나 복원·로그 시핑에 안전한 삭제 가능성을 보장하지 않습니다. DBADB는 백업 파일을 삭제하지 않습니다.

## 로그 시핑 점검 예제

```sql
USE DBADB;
SELECT * FROM report.LogShippingStatus;
SELECT * FROM report.LogShippingJobs;
SELECT TOP(100) * FROM report.LogShippingErrors ORDER BY log_time DESC;
SELECT TOP(100) * FROM report.LogShippingLogBackups ORDER BY backup_finish_date DESC;
EXEC ops.usp_PreviewBackup @BackupType='L',@DatabaseName=N'Sales';
-- 네이티브 기본 백업 작업 조회 후, 필요하면 기존 활성 작업을 시작합니다.
EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales';
-- EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales',@Execute=1;
```

기본 DB의 DBADB 로그 백업과 보조 DB의 모든 DBADB 백업은 제외됩니다. 기본 DB의 전체는 COPY_ONLY입니다. 작업 시작은 비동기이며 네이티브 작업은 자체 보존 설정에 따른 정리를 수행할 수 있습니다. 원격 복사·복원 상태는 각 보조 서버 또는 로그 시핑 모니터에서도 확인합니다.

## 장애 유형별 확인 예제

```sql
USE DBADB;
-- 최근 실패/제외 원문과 생성 명령
SELECT TOP(100) run_id,database_name,backup_type,status,reason,error_number,command
FROM ops.BackupItem WHERE status IN ('FAILED','SKIPPED') ORDER BY started_at DESC;
-- 경로·SIMPLE·오프라인·AG 등 현재 정책 사유
SELECT database_name,backup_type,enabled,directory,state_desc,recovery_model_desc,exclusion_reason
FROM report.EffectiveBackupPolicy WHERE exclusion_reason IS NOT NULL;
-- Agent 마지막 결과 및 알림 설정
SELECT job_key,job_enabled,last_run_at,last_run_status,last_run_message,notify_email_operator
FROM report.ProjectSchedules ORDER BY job_key;
-- 수집 오류 및 이전 스냅샷 상태
SELECT * FROM collect.CapacityDatabase WHERE status<>'SUCCEEDED';
```

경로 오류는 엔진 서비스 계정 권한과 폴더를 확인하고, 로그 오류는 복구 모델과 네이티브 로그 시핑 상태를 확인합니다. 오프라인에서 온라인으로 돌아온 DB는 재시도 설정과 `catch_up_minutes` 안에서 다시 점검합니다. 제외 상태나 설정을 고친 뒤 즉시 실행하려면 미리보기 후 수동 실행할 수 있습니다.

## 실패 대응

1. `report.BackupHealth`에서 FAILED·UNPROTECTED·MISSING·OVERDUE를 먼저 확인합니다. Agent 백업 작업은 실패 다음 점검에서 다시 성공으로 표시되므로 작업 상태가 아니라 이 뷰나 `HEALTH_CHECK` 작업의 실패를 기준으로 판단합니다.
1. `ops.BackupRun`의 실행 ID로 `ops.BackupItem`에서 실패·제외 원문과 명령을 확인합니다. SKIPPED는 정책·지원 범위·동시성 보호에 의한 제외, FAILED는 실행 오류입니다. 전체 결과 SUCCEEDED여도 모든 DB가 제외되었을 수 있으므로 DB별 결과를 함께 확인합니다.
2. 경로 오류는 SQL Server 서비스 계정의 공유·NTFS 권한, 실제 디렉터리와 여유 공간을 확인합니다. 미리보기는 명령 생성만 확인하며 접근 권한이나 실제 성공을 보장하지 않습니다.
3. 로그·차등 실패는 복구 모델·전체 백업 기준을 확인합니다. COPY_ONLY 전체는 차등 기준을 만들지 않습니다. DBADB는 복구 모델·체인을 자동 수정하지 않습니다.
4. 수집 오류는 `collect.CollectionRun/CapacityDatabase`에서 확인합니다. 이전 성공 데이터는 보존되므로 시각·오류도 함께 봅니다. 삭제·재생성 DB는 파일 뷰의 `database_identity_changed`와 저장된 GUID로 확인합니다.
5. KILL·작업 중지·서버 장애로 끊긴 시도는 다음 백업 점검에서 `ATTEMPT_INTERRUPTED_SESSION_ENDED` 실패로 정리되고 재시도 규칙을 따릅니다. 잠금은 연결 종료 시 SQL Server가 해제합니다. 백업 완료 직후 중단되었을 수도 있으므로 고유 이름·UUID·msdb·파일을 대조합니다. v1에서 남은 RUNNING 기록(세션 정보 없음)은 자동 정정하지 않습니다. 중단한 백업을 다시 시작하지 않으려면 해당 Agent 작업을 비활성화합니다.
6. Agent 상태는 `report.ProjectSchedules`에서 확인합니다. 사용자 트랜잭션 안에서 실행·수집·작업 설치 프로시저를 호출하지 않습니다.

## 로그 시핑 대응

보호의 근거는 **로컬 msdb의 기본/보조 DB 등록**입니다. 네이티브 구성 없이 외부 솔루션이 로그를 전달하는 환경은 관리자가 L 정책을 제외해야 합니다. msdb 복원·재구축으로 등록이 사라지면 DBADB 작업을 비활성화하고 구성을 먼저 복구합니다.

기본에서 네이티브 백업 작업의 최근 결과·비활성 여부를, 보조에서 복사·복원과 지연·임계치를 확인합니다. UNKNOWN도 조사 대상입니다. `LogShippingErrors`에서 원문을 확인합니다. REVIEW_LOCATION은 다른 경로의 파일을 검토하라는 표시로 LSN 연속성·실제 적용 가능성을 검증하지 않습니다.

필요한 추가 백업은 `ops.usp_StartLogShippingBackup`으로 기존 작업을 호출합니다. 네이티브 작업은 자체 보존 정책에 따라 파일을 정리할 수 있으므로 미적용 파일이 남도록 운영합니다. DBADB 보존 기준은 네이티브 보존 기간을 대체하지 않습니다. 예상하지 않은 외부 로그 파일이 있으면 해당 파일과 LSN 순서를 조사한 뒤 복원 계획을 결정합니다. SIMPLE 변경·날짜 기준 파일 삭제·보호 우회로 대응하지 않습니다. 구성 변경 시 DBADB 작업을 정지한 후 변경하고 정책 미리보기 후 재개합니다.

## 추가 운영 시나리오

### DB별 백업 옵션을 변경하고 공통 정책으로 복귀

압축·체크섬과 보관 일수는 백업 종류마다 따로 적용됩니다. 아래 예제는 `Sales` 전체 백업 예외 행이 이미 있다고 가정합니다. 행이 없으면 먼저 키인 `database_name`, `backup_type`을 넣어 생성합니다. NULL은 해당 항목의 공통 정책을 상속합니다.

```sql
USE DBADB;
IF NOT EXISTS (SELECT 1 FROM cfg.BackupOverride WHERE database_name=N'Sales' AND backup_type='D')
    INSERT cfg.BackupOverride(database_name,backup_type) VALUES(N'Sales','D');
UPDATE cfg.BackupOverride
SET compression=1, checksum=1, retention_days=30, note=N'월말 복구 요구사항'
WHERE database_name=N'Sales' AND backup_type='D';
SELECT database_name,backup_type,compression,checksum,retention_days,note
FROM report.EffectiveBackupPolicy WHERE database_name=N'Sales';
-- 변경한 항목만 공통 정책으로 복귀합니다.
UPDATE cfg.BackupOverride SET compression=NULL,checksum=NULL,retention_days=NULL,note=NULL
WHERE database_name=N'Sales' AND backup_type='D';
```

`retention_days`는 보존 후보 조회에 사용하며 파일을 삭제하지 않습니다. `copy_only=1`인 전체 백업은 차등 기준을 갱신하지 않습니다. 로그 시핑 기본 DB의 전체 백업은 설정과 관계없이 COPY_ONLY로 계획됩니다.

### 패턴 오류를 수정하고 실제 파일 대조

```sql
USE DBADB;
-- 예외 행이 이미 있는 DB에 미지원 치환자를 넣은 예시
UPDATE cfg.BackupOverride SET filename_pattern=N'[db_name]_[unknown]_[guid]'
WHERE database_name=N'Sales' AND backup_type='D';
EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseName=N'Sales'; -- UNKNOWN_FILENAME_PATTERN_TOKEN
UPDATE cfg.BackupOverride SET filename_pattern=N'[db_name]_[db_id]_[yyyymmddHHmi]_[guid]'
WHERE database_name=N'Sales' AND backup_type='D';
EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseName=N'Sales';
DECLARE @run uniqueidentifier;
EXEC ops.usp_Backup @BackupType='D',@DatabaseName=N'Sales',@RunId=@run OUTPUT;
SELECT run_id,database_name,backup_type,status,reason,started_at,backup_path
FROM ops.BackupItem WHERE run_id=@run;
EXEC collect.usp_BackupHistory;
SELECT h.backup_name,h.backup_type,h.backup_start_date,m.physical_device_name
FROM report.BackupHistory h LEFT JOIN report.BackupMedia m ON m.backup_set_uuid=h.backup_set_uuid
WHERE h.run_id=@run;
```

백업 실행은 실제 파일을 생성합니다. `EMPTY_FILENAME_PATTERN`, `FILENAME_PATTERN_REQUIRES_GUID`, `UNKNOWN_FILENAME_PATTERN_TOKEN`, `INVALID_FILENAME_PATTERN`, `INVALID_BACKUP_FILENAME`, `BACKUP_PATH_TOO_LONG_MAX_259`는 각각 빈 패턴, GUID 누락, 알 수 없는 치환자, 패턴 금지 문자·확장자, 유효하지 않은 최종 파일명, 전체 경로 길이 초과를 뜻합니다. 미리보기에서 오류를 수정한 뒤 실행 결과를 확인합니다.

### 일정 계산과 재시도 판단

```sql
USE DBADB;
-- 기준일이 일요일이면 매주 일요일 02시 슬롯을 계산합니다.
SELECT cfg.ufn_ScheduleSlotAt('2026-11-14T10:00:00','20000102','02:00',10080) AS 최근슬롯;
SELECT database_name,backup_type,current_slot_at,next_policy_slot_at,last_attempt_status,last_attempt_reason,
       retry_count,retry_interval_minutes,catch_up_minutes
FROM report.BackupSchedule WHERE database_name=N'Sales';
-- 현재 정책과 이력으로 슬롯별 실행 대상을 확인합니다.
SELECT p.database_name,p.backup_type,d.is_due,d.scheduled_failed_attempts
FROM report.BackupSchedule p
CROSS APPLY ops.ufn_SlotDue(p.database_name,p.database_guid,p.backup_type,p.current_slot_at,
    p.retry_count,p.retry_interval_minutes,p.catch_up_minutes,SYSDATETIME(),NULL) d
WHERE p.database_name=N'Sales';
```

`is_due=1`은 재시도·슬롯 조건상 대상이라는 뜻이며 실제 백업 가능 여부는 정책과 보호 조건도 확인해야 합니다. 첫 시도 실패 후 재시도 간격이 지났는지, 최대 횟수와 지연 허용 시간을 초과했는지 함께 확인합니다.

### 전체·차등·로그 실행 결과와 실패 원인 조사

```sql
USE DBADB;
DECLARE @run uniqueidentifier;
EXEC ops.usp_Backup @BackupType='D',@DatabaseName=N'Sales',@RunId=@run OUTPUT;
SELECT * FROM ops.BackupRun WHERE run_id=@run;
SELECT database_name,backup_type,status,reason,error_number,command,backup_path
FROM ops.BackupItem WHERE run_id=@run;
-- 정상 전체 백업 기준이 만들어진 뒤 차등과 로그를 각각 미리 봅니다.
EXEC ops.usp_PreviewBackup @BackupType='I',@DatabaseName=N'Sales';
EXEC ops.usp_PreviewBackup @BackupType='L',@DatabaseName=N'Sales';
SELECT * FROM report.BackupHealth WHERE database_name=N'Sales';
```

차등은 유효한 일반 전체 백업 기준이 있어야 하고 로그는 SIMPLE 복구 모델에서 제외됩니다. 실행 중 오류가 발생하면 반환된 오류의 실행 ID나 최근 `ops.BackupRun`을 이용해 개별 DB 결과를 조회합니다. 결과가 `SKIPPED`이면 `reason`을, `FAILED`이면 `reason`과 `error_number`를 확인합니다.

### 용량 수집 실패와 과거 스냅샷 확인

```sql
USE DBADB;
EXEC collect.usp_Capacity; -- 전체 DB 수집
SELECT database_name,status,last_attempt_at,collected_at,error_message
FROM collect.CapacityDatabase WHERE status IN ('FAILED','SKIPPED');
EXEC collect.usp_Capacity @DatabaseName=N'Sales'; -- 한 DB 재수집
SELECT * FROM report.FileSpace WHERE database_name=N'Sales';
SELECT * FROM report.FilegroupSpace WHERE database_name=N'Sales';
SELECT * FROM report.LogSpace WHERE database_name=N'Sales';
SELECT TOP (20) * FROM report.TableSpace WHERE database_name=N'Sales' ORDER BY reserved_mb DESC;
```

실패 또는 제외 상태에서는 이전 성공 스냅샷이 남을 수 있으므로 `collected_at`과 `last_attempt_at`을 구분합니다. 공간 결과를 합산하기 전에 수집 시점과 DB 식별자 변경 여부를 확인합니다.

### Agent 알림·소유자·건강 점검 및 기록 정리

```sql
USE DBADB;
EXEC ops.usp_InstallAgentJobs; -- 누락 작업 생성, 기존 일정과 활성 상태 보존
SELECT job_key,job_enabled,notify_email_operator FROM report.ProjectSchedules ORDER BY job_key;
-- 미리 만든 활성 운영자와 Database Mail을 사용합니다.
EXEC ops.usp_SetJobNotification @OperatorName=N'DBA';
EXEC ops.usp_SetJobOwner @LoginName=N'sa';
SELECT * FROM report.BackupHealth WHERE health_status IN ('FAILED','UNPROTECTED','MISSING','OVERDUE');
-- 문제 발견 시 오류 51004를 반환하므로 Agent 실패 알림에 사용할 수 있습니다.
EXEC ops.usp_CheckBackupHealth;
-- 필요한 경우 별도 배치에서 실행합니다. 백업 파일은 삭제하지 않습니다.
EXEC ops.usp_PurgeOperationalHistory @KeepDays=180;
-- 알림 해제: EXEC ops.usp_SetJobNotification @OperatorName=NULL;
```

건강 점검에서 오류가 발생하면 같은 배치의 이후 문장은 실행되지 않을 수 있습니다. 문제를 해결한 뒤 정리 작업을 별도로 실행합니다. Agent 작업 생성·변경과 정리 프로시저는 사용자 트랜잭션 밖에서 호출합니다.

### 로그 시핑 지연과 네이티브 작업 확인

```sql
USE DBADB;
SELECT local_role,database_name,health_status,minutes_since_last_operation,threshold_minutes,
       last_backup_file,last_copied_date,last_restored_date
FROM report.LogShippingStatus WHERE health_status IN ('OVERDUE','UNKNOWN');
SELECT * FROM report.LogShippingJobs WHERE database_name=N'Sales';
SELECT TOP (50) * FROM report.LogShippingErrors WHERE database_name=N'Sales' ORDER BY log_time DESC;
SELECT TOP (50) * FROM report.LogShippingLogBackups
WHERE database_name=N'Sales' ORDER BY backup_finish_date DESC;
EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales'; -- 실행 없이 작업 확인
-- 운영 판단 후 기존 활성 네이티브 작업 시작:
-- EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales',@Execute=1;
```

작업 시작은 완료를 기다리지 않습니다. 이후 Agent 작업 상태와 보조 서버의 복사·복원 진행 상황을 확인합니다. `REVIEW_LOCATION`은 경로 확인이 필요하다는 뜻이며 복원 가능성 판정이 아닙니다.

## 자동 검증 범위

`tests/run.py`는 무작위 이름의 개발용 컨테이너만 생성·삭제합니다. 호스트 포트를 공개하지 않고 기존 DB 접속 옵션도 없습니다. 암호는 매 실행 생성하며 로그에 기록하지 않습니다. 결과는 Git에서 제외한 `tests/artifacts/2019.log`, `2022.log`에 저장합니다. Linux 엔진의 Windows 드라이브 매핑으로 생성 명령을 실제 실행합니다.

- 신규 설치·작업 비활성·기본 일정, 정책 상속·신규 DB·예외·시스템 보호
- 실패 슬롯의 재시도 간격·횟수 제한, UNPROTECTED/EXCLUDED 구분, 상태 점검 오류 51004, 작업 알림 설정·해제·업그레이드 후 유지
- SIMPLE·오프라인·차등 기준 없음, 잘못된 경로 실패 후 다른 DB 계속 처리
- 전체·차등·로그 VERIFYONLY 및 연속 복원 후 데이터 일치
- 프로젝트·수동·별도 Agent 이력, 재수집 무중복, msdb 정리 후 보관
- 여러 파일 그룹·파티션·인덱스 공간 집계와 수집 실패 시 이전 스냅샷 보존
- 네이티브 프로시저로 생성한 기본/보조 로그 시핑 메타데이터, 수동·예약 로그 차단, 강제 COPY_ONLY 전체
- 두 세션 application lock으로 전체·차등 중복 차단, 전체 잠금 중 로그 백업 허용
- v1 스키마 DB에 설치해 컬럼 추가·데이터 보존 확인(v1 테스트 스키마 `tests/v1-fixture.sql`)
- 요일 앵커·미래 앵커·소수 초 슬롯 계산, catch-up 제한, 예약 실행의 제외 사유 기록·중복 방지, 끊긴 시도 정리
- sysadmin 외 정책 변경 차단·감사, 운영 기록 정리, 작업 소유자 sa 기본·변경, 용량 수집 미지원 DB SKIPPED
- 재설치·업그레이드 후 정책·예외·이력·작업 활성·사용자 수정 일정 보존

테스트의 네이티브 로그 시핑 작업은 실행하지 않습니다. 로컬 메타데이터 보호 시험이며 원격 전송·복원 시험을 대체하지 않습니다.

2026-11-14에 `python3 tests/run.py`로 다음 버전의 위 자동 검증을 모두 통과했습니다.

| 엔진 | 환경 | 결과 |
|---|---|---|
| SQL Server 2019 15.0.4510.2 | Developer / Ubuntu 20.04 컨테이너 | PASS |
| SQL Server 2022 16.0.4325.4 | Developer / Ubuntu 22.04 컨테이너 | PASS |

아래 Windows 인수 검증은 이 환경에서 수행하지 않았습니다.

## Windows 인수 검증

Windows SQL Server **2019·2022 각각의 격리된 인스턴스**에서 아래를 수행합니다. 운영 데이터·기존 로그 시핑 구성에 테스트 SQL을 실행하지 않습니다.

| 시나리오 | 확인 |
|---|---|
| 배포 | 신규·재설치·upgrade, 정책·이력·수정 일정·활성 상태 보존 |
| 경로 | 로컬·UNC에 서비스 계정 권한 부여 후 D/I/L 성공, 권한 제거 후 실패 원문 |
| 복원 | 일회용 FULL DB에 쓰기·D/I/L 백업 후 다른 DB명으로 순차 복원·데이터 일치 |
| 시스템 | master/model/msdb 전체 성공·tempdb 제외, 별도 환경에서 시스템 DB 복구 절차 |
| AG | 기본/보조 모두 AVAILABILITY_GROUP_NOT_SUPPORTED 제외·명령 미생성 |
| 상태·식별자 | SIMPLE·OFFLINE·STANDBY·스냅샷·미존재·따옴표/대괄호 포함 DB 이름 |
| 동시성 | 같은 DB의 두 세션 D/L, 외부 백업과 겹칠 때 제외/엔진 결과 기록 |
| 일정 | 02시·01시·15분, DB별 변경, 중지 후 재개 한 번 보완 |
| 로그 시핑 기본 | 두 서버 구성 후 enabled=1·수동 실행도 L 차단, 전체 COPY_ONLY |
| 네이티브 장애 | 기본 작업 비활성·실패 때 대체 로그 미생성, 상태·보조 프로시저 확인 |
| 로그 시핑 보조 | 복원/대기 모두 백업 제외, 복사·복원 지연과 실패 확인 |
| 복원 연속성 | DBADB 전체 실행 중에도 네이티브 로그 복사·복원 연속 성공 |
| 보존 | 검토 목록은 안전 삭제 목록이 아니며 DBADB 파일 삭제가 없는지 확인 |

## Microsoft 근거 문서

- [시스템 DB 백업](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/back-up-and-restore-of-system-databases-sql-server)
- [백업 이력](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-history-and-header-information-sql-server)
- [로그 시핑 구성 테이블·프로시저](https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/log-shipping-tables-and-stored-procedures)
- [네이티브 작업을 sp_start_job으로 호출](https://learn.microsoft.com/en-us/sql/tools/sqllogship-application)
- [로그 시핑 모니터링](https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/monitor-log-shipping-transact-sql)
- [파티션 공간 통계·권한](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-partition-stats-transact-sql)

### 백업 파일명 패턴

기본 정책은 `cfg.BackupDefault.filename_pattern`에서 USER/SYSTEM과 D(전체), I(차등), L(로그)별로 지정합니다. DB별 `cfg.BackupOverride.filename_pattern`이 NULL이면 해당 기본 정책을 상속합니다. 업그레이드와 신규 설치의 기본값은 `[db_name]_[db_id]_[guid]`입니다.

```sql
UPDATE cfg.BackupDefault SET filename_pattern=N'[db_name]_[yyyymmddHHmi]_[guid]'
WHERE database_scope='USER' AND backup_type='D';
UPDATE cfg.BackupOverride SET filename_pattern=N'archive_[db_id]_[guid]'
WHERE database_name=N'Sales' AND backup_type='L';
-- 다시 기본 정책을 상속:
UPDATE cfg.BackupOverride SET filename_pattern=NULL
WHERE database_name=N'Sales' AND backup_type='L';
SELECT database_name,backup_type,directory,filename_pattern,exclusion_reason
FROM report.EffectiveBackupPolicy WHERE database_name=N'Sales';
EXEC ops.usp_PreviewBackup @BackupType='D',@DatabaseName=N'Sales';
SELECT TOP (20) database_name,backup_type,started_at,status,reason,backup_path
FROM ops.BackupItem WHERE database_name=N'Sales' ORDER BY started_at DESC;
```

사용 가능한 치환자는 파일명용으로 변환한 이름 `[db_name]`, DB ID `[db_id]`, 시도마다 생성되는 하이픈 없는 GUID `[guid]`, DB별 시도 시작의 서버 현지 시간 `[yyyymmddHHmi]`입니다. 대소문자를 구분하며 반복할 수 있고 `[guid]`는 필수입니다. 확장자는 지정하지 마세요. 전체와 차등은 `.bak`, 로그는 `.trn`이 자동으로 붙습니다. 예를 들어 패턴 `[db_name]_[yyyymmddHHmi]_[guid]`는 `Sales_202611140159_0123456789abcdef0123456789abcdef.bak`(전체 또는 차등)이나 `Sales_202611140159_0123456789abcdef0123456789abcdef.trn`(로그)을 만듭니다. 같은 분의 재시도도 GUID가 다릅니다.

빈 패턴, 알 수 없는 치환자, 금지 문자, 유효하지 않은 파일명 또는 259자를 초과하는 전체 경로는 명령 생성 전에 제외되며 미리보기의 `exclusion_reason`과 실행 이력의 `reason`에서 확인할 수 있습니다. 미리보기의 GUID와 시작 시간은 예시이며 실제 실행 시 새로 생성됩니다. 로그 시핑 자체의 파일명에는 영향을 주지 않습니다.
