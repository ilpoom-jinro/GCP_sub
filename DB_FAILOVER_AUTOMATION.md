# GCP DR DB 장애 조치 자동화

이 문서는 AWS RDS에서 GCP Cloud SQL로 복제 중인 PostgreSQL의 실제 장애 조치 절차를 설명합니다.

## 자동화 범위

- GitHub Actions `Promote GCP DR Database`는 DMS 상태를 확인하고 Cloud SQL을 promote합니다.
- `preflight` 모드는 읽기 전용입니다.
- `promote` 모드는 현재 AWS -> GCP DMS 스트림을 종료하고 Cloud SQL을 독립 primary writer로 바꿉니다.
- 이 워크플로는 AWS 쓰기 차단, Route 53 전환, AWS 복귀 후 역방향 복제를 자동으로 수행하지 않습니다.

## Promote 전 필수 조건

1. AWS 애플리케이션과 RDS 쓰기가 이미 차단됐거나, 실제 AWS 장애로 더 이상 쓰기가 불가능해야 합니다.
2. 계획된 전환이면 DMS 작업이 `RUNNING` 및 `CDC`이고 복제 지연이 0인지 확인합니다.
3. GCP Cloud SQL 인스턴스 `dr-standby-postgres`가 `RUNNABLE`이어야 합니다.
4. Route 53 GCP 상태 검사가 정상이어야 합니다.

## 실행 방법

1. GitHub Actions에서 `Promote GCP DR Database`를 실행합니다.
2. 먼저 `mode: preflight`로 실행해 사전 조건을 확인합니다.
3. 실제 승격 때만 다음 값을 모두 입력합니다.

| 입력 | 값 |
| --- | --- |
| mode | promote |
| aws_writes_fenced | true |
| confirmation | PROMOTE_CLOUDSQL_DR |

4. 워크플로의 마지막 단계에서 Cloud SQL의 `masterInstanceName`이 비어 있고 상태가 `RUNNABLE`인지 확인합니다.
5. 그 다음에만 GCP 애플리케이션으로 쓰기 트래픽을 전환합니다.

## 복귀 주의사항

Cloud SQL을 promote한 뒤에는 기존 DMS 작업을 AWS로 역전환할 수 없습니다. AWS 복구 후에는 AWS RDS를 재초기화하고, Cloud SQL -> AWS RDS native PostgreSQL logical replication으로 데이터를 따라잡아야 합니다. 이 절차가 완료되기 전에는 AWS에 쓰기를 다시 허용하면 안 됩니다.
