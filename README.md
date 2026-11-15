# DBADB — SQL Server DBA 도구

인스턴스마다 설치하는 T-SQL 관리 DB입니다. 백업 정책·실행·이력, Agent 일정, 용량과 운영 상태를 SQL로 관리합니다. **SQL Server 2019 이상 / Windows / SQL Server Agent**를 대상으로 하며 AG DB는 감지해 제외합니다.

상세 절차와 예제는 [설치 매뉴얼](docs/installation.md)과 [운영 매뉴얼](docs/operations.md)에서 확인할 수 있습니다.

## 설치·업그레이드

`sysadmin`으로 연결하고 Agent가 시작을 마친 상태에서 **저장소 루트**에서 실행합니다. SSMS에서는 SQLCMD 모드를 사용합니다.

```powershell
sqlcmd -S localhost -E -b -i install.sql
sqlcmd -S localhost -E -b -i upgrade.sql
```

DBADB가 없으면 생성합니다. 업그레이드 전에는 DBADB Agent 작업을 비활성화하고 실행 중인 작업이 끝난 뒤 배포합니다. 기존 DB의 복구 모델·파일 설정은 바꾸지 않습니다. 재설치·업그레이드 시 정책·예외·이력, 등록된 작업의 활성 상태·일정은 보존하며 코드와 작업 1번 단계 명령을 갱신합니다. 누락된 기본 행·작업만 생성하고 이름이 같은 외부 작업은 인수하지 않습니다. 미래 버전이 설치된 DB에 구버전을 배포하면 중단합니다. 설치 전체가 단일 트랜잭션은 아니므로 실패 원인 해결 후 재실행합니다. 동시 배포는 피합니다.

**새 Agent 작업 7개는 모두 비활성**이고 차등 정책도 기본 비활성입니다. 경로 설정·미리보기 후 필요한 작업만 활성화합니다. v1 DB에 배포하면 재시도 설정 컬럼과 상태 점검 작업을 추가하고 기존 설정·작업 상태는 그대로 둡니다.

## 경로·정책

폴더를 미리 만들고 **SQL Server 서비스 계정**에 로컬 폴더 또는 UNC 공유·NTFS 쓰기 권한을 부여합니다. SSMS 사용자 권한으로 대신할 수 없습니다. 매핑 드라이브 대신 UNC를 사용합니다. DBADB는 폴더 생성·파일 삭제를 하지 않습니다. 백업 파일명에는 GUID를 넣어 기존 파일을 덮어쓰지 않습니다. Windows 절대 경로·UNC를 허용하며 최종 경로는 259자 이내입니다.

```sql
USE DBADB;
UPDATE cfg.BackupDefault SET directory=N'D:\SQLBackup\User' WHERE database_scope='USER';
UPDATE cfg.BackupDefault SET directory=N'\\backup-server\sql\instance01\system' WHERE database_scope='SYSTEM';

-- D=전체, I=차등, L=로그. NULL 필드는 해당 범위의 기본값을 상속합니다.
INSERT cfg.BackupOverride(database_name,backup_type,directory,retention_days,note)
VALUES(N'Sales','D',N'E:\SalesBackup',30,N'별도 보관');
INSERT cfg.BackupOverride(database_name,backup_type,enabled,note)
VALUES(N'Scratch','L',0,N'업무 정책상 제외');
INSERT cfg.BackupOverride(database_name,backup_type,interval_minutes)
VALUES(N'Sales','L',30);
-- 실패한 슬롯의 재시도: 기본 2회, 15분 간격
UPDATE cfg.BackupDefault SET retry_count=3,retry_interval_minutes=10 WHERE database_scope='USER' AND backup_type='D';
-- 일요일 02:00 주간 전체, 슬롯 시작 후 3시간이 지나면 다음 주를 기다림
INSERT cfg.BackupOverride(database_name,backup_type,interval_minutes,anchor_date,catch_up_minutes)
VALUES(N'Archive','D',10080,'20000102',180);
UPDATE cfg.BackupDefault SET enabled=1 WHERE database_scope='USER' AND backup_type='I';

SELECT * FROM report.EffectiveBackupPolicy ORDER BY database_name,backup_type;
EXEC ops.usp_PreviewBackup @BackupType='D';
EXEC ops.usp_PreviewBackup @BackupType='L',@DatabaseName=N'Sales';
```

설정은 UPDATE로 수정하고 예외는 DELETE로 해제합니다. 모든 백업 제외는 D/I/L 각각 `enabled=0`으로 설정합니다. 디렉터리 NULL은 상속이고 빈 문자열은 경로 미설정으로 제외됩니다. 삭제·이름 변경 DB의 예외는 이름에 연결된 채 남으므로 운영자가 정리합니다. 새 사용자 DB는 즉시 기본 정책을 상속합니다. **DBADB 자체도 사용자 DB 정책 대상**입니다.

기본값은 사용자 전체 매일 02:00, 로그 15분 간격, 시스템 전체 매일 01:00입니다. 전체·차등 보존 기준은 14일, 로그는 7일입니다. `master/model/msdb`는 전체만 지원하고 `tempdb`는 제외합니다. `compression/checksum`은 기본 1, 전체 `copy_only`는 기본 0입니다. 일반 전체는 다른 도구의 차등 기준을 바꿀 수 있으므로 병행 도구의 정책도 검토합니다. 복구 모델은 자동 변경하지 않습니다. SIMPLE 로그·기준 없는 차등은 제외하고, 엔진에서 판정하는 복구 체인·미디어 오류 등은 실패 원문을 기록합니다.

## 일정·실행

백업 Agent 작업은 **1분마다 정책을 점검**합니다. 실제 백업 주기·시각은 `interval_minutes/start_time`으로 제어해 DB별 재정의를 지원합니다. 시각은 서버 현지 시각이며 초는 0입니다. `anchor_date`(기본 2000-01-01, 토요일)의 `start_time`을 기준으로 고정 간격을 계산하므로 주 단위 이상 주기의 요일은 `anchor_date`로 정합니다(예: 일요일 주간 전체는 `anchor_date='2000-01-02', interval_minutes=10080`). 월 단위처럼 길이가 바뀌는 주기는 지원하지 않습니다. 일광 절약 시간으로 중복된 슬롯은 다시 실행하지 않고 건너뛴 시간은 다음 점검에서 보완합니다.

활성화·재시작 시 최근 시점의 미처리 백업 한 번을 즉시 실행합니다. 중단 기간의 모든 백업을 따라 실행하지 않습니다. 업무 시간에 작업을 활성화해 전체 백업이 바로 시작되는 것을 막으려면 `catch_up_minutes`(기본 0=제한 없음)를 설정합니다. 실행 시작 시각 기준으로 슬롯 시작 후 그 시간이 지나면 첫 시도·재시도 모두 다음 슬롯을 기다립니다. 제한 안에 시작한 실행은 여러 DB를 차례로 처리하는 동안 시간이 지나도 끝까지 처리합니다. 성공·정책 제외는 슬롯당 한 번 기록합니다. **예약 실행이 실패한 슬롯은 같은 슬롯 안에서 직전 시도 종료 후 `retry_interval_minutes`(기본 15분)가 지나면 최대 `retry_count`(기본 2)회 다시 시도**하며, 재시도마다 새 파일명을 사용합니다. 예약 실행도 정책상 제외된 DB의 사유를 SKIPPED로 기록합니다. 일반적인 제외는 슬롯당 한 번 기록하고, 오프라인이나 DB 식별자 변경은 일시적인 제외로 취급해 같은 슬롯에서 다시 점검합니다. 오프라인 중 확인할 수 없던 DB GUID가 온라인 후 확인되면 이전 재시도 이력과 별개로 다음 점검에서 실행될 수 있습니다. 실행 도중 DB가 내려가거나 재생성된 경우는 실패와 같은 방식으로 재시도합니다. KILL·작업 중지·서버 재시작으로 끊긴 시도는 다음 점검에서 `ATTEMPT_INTERRUPTED_SESSION_ENDED` 실패로 정리되어 재시도 대상이 되므로, 중단한 백업을 다시 시작하지 않으려면 해당 작업을 비활성화합니다. SSMS 취소·클라이언트 시간 초과로 중단된 수동 실행은 연결이 살아 있으면 백업 잠금을 계속 잡고 있을 수 있습니다. 다른 세션의 점검이 이를 `ATTEMPT_ABORTED_SESSION_<id>_IDLE_MAY_HOLD_BACKUP_LOCK` 실패로 표시하며, 그 연결을 닫거나 같은 연결에서 DBADB 백업을 다시 실행하면 잠금이 풀립니다. 일광 절약 시간 해제로 1시간이 반복되면 그동안 로그 백업이 멈추므로 DST 지역에서는 RPO에 반영합니다. 수동 실행의 성공은 슬롯을 완료로 처리하지만 수동 실패·제외는 예약 슬롯에 영향을 주지 않습니다. 재시도 기회가 끝나면 다음 슬롯이나 수동 실행을 기다립니다. 주기가 재시도 간격보다 짧으면 다음 슬롯이 재시도 역할을 합니다. 동시성 충돌은 다음 점검에서 재시도합니다. 실행 직전에야 확인되는 제외(잘못된 경로·경로 길이 초과·차등 기준 없음)는 예약 슬롯을 완료로 처리하므로, 같은 슬롯에서 고쳤다면 다음 슬롯을 기다리거나 수동 실행합니다.

```sql
USE DBADB;
SELECT * FROM report.BackupSchedule;
SELECT * FROM report.ProjectSchedules;
-- 경로·미리보기 검토 후 필요한 작업만 활성화합니다.
DECLARE @job uniqueidentifier=(SELECT job_id FROM cfg.AgentJob WHERE job_key='USER_FULL');
EXEC msdb.dbo.sp_update_job @job_id=@job,@enabled=1;
-- USER_LOG, SYSTEM_FULL, HISTORY, CAPACITY도 동일하게 활성화합니다.
-- HEALTH_CHECK는 첫 백업이 끝난 뒤 활성화합니다(아래 '실패 알림').
-- USER_DIFFERENTIAL은 차등 정책을 활성화한 경우 선택합니다.

-- 수동 실행은 시각·주기만 생략하며 제외·로그 시핑 보호는 그대로 적용됩니다.
DECLARE @run uniqueidentifier;
EXEC ops.usp_Backup @BackupType='D',@DatabaseName=N'Sales',@RunId=@run OUTPUT;
SELECT * FROM ops.BackupItem WHERE run_id=@run;
EXEC ops.usp_Backup @BackupType='D',@DatabaseScope='SYSTEM';
EXEC ops.usp_Backup @BackupType='I',@DatabaseName=N'Sales';
EXEC ops.usp_Backup @BackupType='L',@DatabaseName=N'Sales';
```

같은 DB의 DBADB 전체·차등 백업은 하나의 application lock으로, 로그 백업은 별도 잠금으로 직렬화합니다. 엔진이 전체·차등 중 로그 백업을 허용하므로 긴 전체 백업 중에도 로그 백업이 계속됩니다. 이미 실행 중인 외부 백업도 같은 기준(전체·차등끼리, 로그끼리)으로 점검하지만 외부 도구는 이 잠금을 공유하지 않으므로 모든 외부 실행과 원자적으로 조정하지는 못합니다. 일부 DB 실패 후 나머지 처리를 마친 뒤 오류 51002를 반환해 Agent도 실패를 인지합니다. 오류 시 SQL Server는 OUTPUT 값을 반환하지 않으므로 **출력·오류 메시지의 실행 ID**로 조회합니다.

Agent 캐시인 `ProjectSchedules.agent_cached_next_run_at`은 갱신 지연이 있습니다. 정책의 다음 시각은 `BackupSchedule.next_policy_slot_at`에서 확인합니다. 작업·일정 비활성 또는 Agent 중지는 실행되지 않는 원인입니다. 이력 수집은 15분, 용량 수집·상태 점검은 1시간 간격입니다. 기존 외부 작업의 설정·일정은 변경하지 않습니다.

## 실패 알림

백업 작업은 실패한 실행에서만 Agent 작업 실패가 되고, 다음 점검에 할 일이 없으면 다시 성공으로 표시됩니다. Agent 작업 상태만으로는 미해결 실패를 알 수 없으므로 **`HEALTH_CHECK` 작업**이 `report.BackupHealth`에 FAILED·UNPROTECTED·MISSING·OVERDUE가 남아 있는 동안 매번 오류 51004로 실패합니다. 첫 백업 전에는 모든 정책이 MISSING이므로 첫 백업이 끝난 뒤 활성화합니다.

```sql
USE DBADB;
EXEC ops.usp_CheckBackupHealth; -- 문제 행을 반환하고, 있으면 51004
-- Database Mail과 Agent 운영자를 먼저 구성합니다. DBADB는 운영자·메일 설정을 만들지 않습니다.
EXEC ops.usp_SetJobNotification @OperatorName=N'DBA Team'; -- 관리 작업 7개: 실패 시 메일
EXEC ops.usp_SetJobNotification;                           -- 해제
SELECT job_key,notify_level_email,notify_email_operator FROM report.ProjectSchedules;
```

알림 설정은 재설치·업그레이드 후에도 유지됩니다. 이후 버전에서 새 작업이 추가되면 다시 실행해 새 작업에도 적용합니다. Agent 속성에서 메일 프로필을 활성화해야 실제로 발송됩니다. 상태 점검 작업은 문제가 해결될 때까지 매시간 알림을 보내므로 해결할 수 없는 항목은 예외로 명시해 정리합니다.

## 로그 시핑 보호·보조 도구

**로컬 msdb 등록을 감지하고 로그 시핑 기본 DB의 DBADB 로그 백업을 항상 차단합니다.** `enabled=1`, 수동 실행, 비활성화된 네이티브 작업도 이 보호를 해제하지 못합니다. 보조 서버에 전달되지 않은 추가 로그 파일로 복원 순서가 누락되지 않도록 별도 로그 백업을 만들지 않습니다. COPY_ONLY 로그 우회 옵션도 제공하지 않습니다.

- 기본 DB의 로그는 기존 로그 시핑 작업이 담당합니다. DBADB 전체는 강제 `COPY_ONLY`이며 차등은 별도의 정상 전체 기준이 필요합니다.
- 보조 DB는 모든 DBADB 백업을 제외합니다.
- 기존 로그 시핑 작업·보존 설정은 그대로 둡니다. 실행 직전 메타데이터도 재검사합니다.
- 메타데이터 가시성을 보장하기 위해 실행은 sysadmin만 허용합니다. 구성 변경은 백업을 멈춘 유지보수 시간에 수행합니다. 외부 구성 변경과 실행 사이를 원자적으로 잠그지는 못합니다.

```sql
USE DBADB;
SELECT * FROM report.LogShippingStatus; -- 로컬 역할·최근 시각·임계치·복원 지연
SELECT * FROM report.LogShippingJobs;   -- 기본 백업 / 보조 복사·복원 작업 상태
SELECT * FROM report.LogShippingErrors ORDER BY log_time DESC;
SELECT * FROM report.LogShippingLogBackups ORDER BY backup_finish_date DESC;
-- REVIEW_LOCATION은 등록 폴더 밖의 파일에 대한 검토 신호이며 충돌 확정 판정이 아닙니다.
EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales';             -- 조회
EXEC ops.usp_StartLogShippingBackup @DatabaseName=N'Sales',@Execute=1;  -- 기존 작업 시작
```

보조 프로시저는 활성 상태의 기존 작업을 `sp_start_job`으로 시작하며 완료를 기다리지 않습니다. 비활성·누락 작업은 오류를 반환하고 임의로 활성화하지 않습니다. 네이티브 작업 자체는 복사·정리·모니터링 동작을 수행할 수 있습니다. 상태 뷰는 로컬 등록 DB만 표시하므로 원격 보조는 각 서버 또는 기존 모니터에서도 확인합니다. 시각이 없으면 UNKNOWN이고 보조의 복원 임계치는 의도한 `restore_delay`와 함께 해석합니다.

로그 사용량 증가 시 DBADB 보호를 우회하지 말고 네이티브 백업·복사·복원 작업, 경로·보존·미적용 파일을 확인합니다. 복구 모델 변경이나 날짜만으로 파일 삭제를 수행하지 않습니다. 상세 절차는 [운영·실환경 검증](docs/operations.md)을 참고하세요.

## 이력·용량·운영 조회

```sql
USE DBADB;
EXEC collect.usp_BackupHistory;
SELECT h.*,m.physical_device_name,m.family_sequence_number,m.mirror
FROM report.BackupHistory h LEFT JOIN report.BackupMedia m ON m.backup_set_uuid=h.backup_set_uuid
ORDER BY h.backup_finish_date DESC;
SELECT * FROM ops.BackupRun ORDER BY started_at DESC;
SELECT * FROM ops.BackupItem WHERE status IN ('FAILED','SKIPPED') ORDER BY started_at DESC;
SELECT * FROM collect.CollectionRun ORDER BY started_at DESC;
EXEC collect.usp_Capacity @DatabaseName=N'Sales'; -- 생략하면 전체 DB
SELECT * FROM collect.CapacityDatabase; -- 아직 성공한 스냅샷이 없는 DB의 오류 포함
SELECT * FROM report.FileSpace;
SELECT * FROM report.FilegroupSpace;
SELECT * FROM report.TableSpace ORDER BY reserved_mb DESC;
SELECT * FROM report.LogSpace;
SELECT * FROM report.BackupHealth WHERE health_status<>'OK';
SELECT * FROM report.DiskSpace;
SELECT * FROM report.ActiveRequests ORDER BY blocking_session_id DESC;
SELECT * FROM report.RetentionCandidates;
```

이력은 UUID로 새 행만 증분 저장하고 미수집 msdb 기록과 합칩니다. 오래 실행 중인 백업·이력 적재·msdb ID 재설정을 처리하기 위해 단순 최대 ID 대신 UUID의 존재 여부를 비교합니다. 재수집 시 중복 저장하지 않습니다. 스트라이프·미러 경로는 별도 행이므로 조인 후 백업 크기를 단순 합산하지 않습니다. 프로젝트 고유 백업 이름으로 실행을 연결하며 나머지는 `UNATTRIBUTED`입니다. 수동·외부 작업 여부를 추정하지 않습니다. **이미 삭제된 미수집 이력·외부 실패 기록은 보장하지 않습니다.** msdb 정리는 수집 성공 확인 후 수행합니다. `collect.BackupHistory`는 영구 보관합니다. DBADB 운영 기록은 자동 삭제하지 않으며, `EXEC ops.usp_PurgeOperationalHistory @KeepDays=90;`(최소 30일)으로 오래된 SKIPPED 시도·빈 실행·수집 실행 기록만 정리합니다. 성공·실패 시도는 백업 파일과 실행을 연결하므로 남깁니다.

용량은 마지막 성공한 스냅샷입니다. 갱신 실패 시 이전 데이터를 보존하고 수집 상태·오류·시각을 표시합니다. 파일 그룹은 ROWS만 집계하고 로그 파일별 사용량은 NULL, DB 전체 로그 사용량은 `LogSpace`로 제공합니다. 테이블은 파티션 통계를 한 번씩 집계하고 행 수는 heap/clustered 부분만 합칩니다. `data_pages`는 기본 저장소 데이터·LOB·overflow, `index_pages`는 나머지 사용 공간(비리프·관리 페이지 포함)입니다. 메모리 최적화·FILESTREAM 사용량은 이 테이블 집계 범위 밖입니다. AG·대기·오프라인 DB는 `SKIPPED`와 사유를 기록하고 이전 스냅샷을 유지하며 작업을 실패시키지 않습니다. 실제 수집 오류만 FAILED와 오류 51003입니다.

`BackupHealth`는 정책 주기의 두 배를 넘긴 성공 백업을 OVERDUE로 봅니다. **UNPROTECTED**는 정책이 활성인데 백업을 만들 수 없는 상태입니다(경로 미설정·잘못된 경로·경로 길이 초과·AG·온라인 아님·차등 기준 없음). **EXCLUDED**는 운영자가 `enabled=0`으로 끈 정책과 tempdb·스냅샷·시스템 DB 차등/로그·SIMPLE 로그·대기(STANDBY)·로그 시핑처럼 설계상 제외입니다. 의도한 제외라면 예외에 `enabled=0`을 기록해 UNPROTECTED에서 빼냅니다. 로그 시핑 로그는 EXCLUDED이며 별도 상태에서 확인합니다. `DiskSpace`는 DB 파일 볼륨만 보여주며 별도 백업 볼륨·UNC의 용량을 보장하지 않습니다. `RetentionCandidates`는 **날짜 기준 검토 목록**으로 복원 의존성·로그 시핑 적용·파일 존재·삭제 안전성을 증명하지 않습니다. `deletion_safety_verified`는 항상 0이며 실제 파일 삭제는 구현하지 않습니다.

## 권한·검증

배포·실행·수집·초기 버전 조회는 sysadmin용 DBA 인터페이스입니다. 새 Agent 작업의 소유자는 기본 제공 `sa`(SID 0x01)이며, 비활성화된 sa도 작업 소유자로 동작합니다. 기존 작업의 소유자는 바꾸지 않으며 `EXEC ops.usp_SetJobOwner @LoginName=N'...'`으로 다른 sysadmin 로그인으로 변경합니다. 백업 정책 테이블(`cfg.BackupDefault/BackupOverride`)은 sysadmin 실행 BACKUP의 저장 위치를 정하므로 트리거가 sysadmin 외 변경을 거부하고(오류 51005) 모든 변경을 `cfg.ConfigAudit`에 기록합니다. db_owner는 트리거를 끌 수 있으므로 이는 보안 경계가 아니라 방어선·감사 기록입니다. DBADB의 db_owner를 sysadmin 외 계정에 부여하지 않습니다. 트리거가 있으므로 정책 테이블 변경에 `OUTPUT`을 쓸 때는 `OUTPUT ... INTO`를 사용합니다. 일반 사용자에게 실행 권한을 공개하거나 DBADB를 TRUSTWORTHY로 설정하지 않습니다. 최소 권한 위임은 후속 범위입니다.

| 영역 | 내용 |
|---|---|
| `cfg` | 기본 정책, 예외, 배포 버전, 작업 등록 |
| `ops` | 미리보기·실행·실행 이력·네이티브 로그 시핑 작업 호출 |
| `collect` | msdb 증분 이력·DB 문맥의 용량 수집 |
| `report` | 정책·일정·이력·용량·운영·로그 시핑 조회 |

```bash
# Docker와 Python 3 필요. 새 일회용 컨테이너만 생성·삭제합니다.
python3 tests/run.py
python3 tests/run.py --version 2022 --keep
```

자동 검증은 SQL Server 2019·2022 Linux 컨테이너를 사용합니다. **Windows 서비스 계정·UNC ACL·AG·실제 서버 간 로그 시핑 전송/복원은 별도 실환경 확인 대상**입니다. [검증 절차](docs/operations.md)에 범위를 기록했습니다. 복원 자동화·파일 삭제·인덱스/통계 유지보수·중앙 관리·웹 UI는 포함하지 않습니다. 테스트의 RESTORE는 일회용 환경에서만 수행합니다.
