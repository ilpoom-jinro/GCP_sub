# AWS-GCP DR 운영 현황 및 리허설 런북

- 기준일: 2026-07-16
- 기본 운영: AWS ap-northeast-2
- DR 운영: GCP asia-northeast3
- 운영 원칙: 평상시에는 AWS RDS를 기준 데이터베이스로 사용하고, 계획된 장애 전환 시에만 GCP Cloud SQL을 쓰기 주 데이터베이스로 승격합니다.

## 1. 목표

이 DR 구성의 목표는 다음 두 가지입니다.

1. AWS 장애 시 Route 53이 GCP GKE 서비스로 트래픽을 전환하고, GKE의 HPA 및 Cluster Autoscaler가 부하에 맞춰 확장합니다.
2. AWS RDS에서 GCP Cloud SQL로 평상시 CDC 복제를 유지하다가, 장애 시 Cloud SQL을 주 DB로 승격합니다. AWS 복구 후에는 GCP에서 AWS로 데이터를 되돌리고 AWS를 다시 주 DB로 만든 뒤 AWS에서 GCP로의 CDC를 재구성합니다.

브라우저 화면 우측 상단의 Traffic Origin 배지는 현재 응답 출처를 표시합니다.

- AWS 정상 운영: AWS PRIMARY / ap-northeast-2
- GCP DR 운영: GCP DR / asia-northeast3

## 2. 주요 구성

| 구분 | 구성 |
| --- | --- |
| AWS 주 서비스 | EKS, `financial-service-db` RDS, `financial_service` DB |
| GCP DR 서비스 | GKE `gke-prd-cluster`, Cloud SQL `dr-standby-postgres` |
| GCP Gateway 고정 IP | `8.230.27.50` |
| Cloud SQL 사설 IP | `10.177.232.3` |
| GCP PSA 대역 | `10.177.232.0/24` |
| 서비스 도메인 | `ilpumjinro.store` |
| AWS 상태 검사 도메인 | `health.ilpumjinro.store/healthz` |
| Route 53 강제 전환 게이트 | CloudWatch Alarm `financial-stock-web-dr-force-failover` |
| AWS Router 프록시 | `cloudsql-failback-proxy`, `15432 -> 10.177.232.3:5432` |
| Headscale 경로 | AWS VPC, GCP VPC 및 PSA 대역을 OCI Headscale에서 승인 |

Tailnet IP는 재등록이나 인스턴스 재생성 시 바뀔 수 있습니다. 마지막 확인값은 GCP Router `100.64.0.8`, AWS Router `100.64.0.9`였으나, ACL과 경로 승인 전에 항상 실제 값을 다시 확인합니다.

## 3. 구현된 운영 흐름

### 정상 상태

1. AWS RDS에서 GCP Cloud SQL로 GCP DMS 연속 마이그레이션(CDC)을 수행합니다.
2. Cloud SQL은 DMS 대상 replica이며, GCP 애플리케이션의 DB 쓰기는 차단 상태를 유지합니다.
3. Route 53은 AWS를 주 엔드포인트로 응답합니다.

### DR Failover to GCP

워크플로우: `.github/workflows/dr-failover.yml`

1. AWS/GCP 상태, DMS CDC, Route 53, Cloud SQL 상태를 사전 점검합니다.
2. AWS EKS 애플리케이션의 RDS 쓰기를 CodeBuild 기반 fence로 차단합니다.
3. Cloud SQL을 승격하고 GCP 애플리케이션의 DB 접근을 활성화합니다.
4. GCP readiness를 확인합니다.
5. CloudWatch 강제 장애 게이트를 `ALARM`으로 전환하여 Route 53이 GCP로 전환되도록 합니다.

`preflight`은 상태만 점검하며 리소스를 변경하지 않습니다. 실제 전환은 쓰기 차단 확인과 `FAILOVER_TO_GCP` 확인 문자열이 있어야 실행됩니다.

### DR Failback to AWS

워크플로우: `.github/workflows/dr-failback.yml`

1. GCP 애플리케이션의 Cloud SQL 쓰기를 fence로 차단합니다.
2. Cloud SQL 데이터를 `pg_dump`/`pg_restore`로 AWS RDS에 초기 복원합니다.
3. Cloud SQL publisher와 AWS RDS subscriber를 구성해 `dr_failback_subscription` 역복제를 시작합니다.
4. AWS RDS가 GCP 변경사항을 받았는지 확인한 뒤 AWS 애플리케이션 쓰기를 복구합니다.
5. Route 53 강제 장애 게이트를 정상으로 돌려 AWS로 트래픽을 복귀시킵니다.

`pg_dump`/`pg_restore`는 failback 실행 시점의 초기 동기화입니다. 그 뒤의 변경사항은 logical replication subscription이 계속 받아야 합니다.

### Rearm AWS to GCP DMS

워크플로우: `.github/workflows/dr-rearm-aws-to-gcp-dms.yml`

1. GCP 쓰기 fence가 유지되는지 확인합니다.
2. 기존 Cloud SQL -> AWS 역복제 subscription을 제거합니다.
3. 이전 DMS job 및 destination connection profile을 정리합니다.
4. Cloud SQL을 새 DMS 대상 replica 역할로 만들기 위해 필요한 DB를 정리하고 AWS -> GCP 연속 마이그레이션을 새로 생성합니다.
5. Cloud SQL demote, verify, CDC start까지 완료해 AWS를 다시 권위 있는 주 DB로 만듭니다.

이 과정은 Cloud SQL에 기존 사용자 DB가 남아 있으면 DMS 초기 적재가 불가능하므로, database owner 권한이 있는 `GCP_DMS_REARM_DB_OWNER_USER` 및 `GCP_DMS_REARM_DB_OWNER_PASSWORD`가 필요합니다. 이는 개인 Google 계정이 아니라 Cloud SQL 안의 해당 DB 소유자 계정입니다.

## 4. 현재까지 완료된 사항

- GKE DR 서비스, Artifact Registry 이미지 미러링, Cloud SQL Secret, Gateway 고정 IP 및 TLS 구성을 배포했습니다.
- GKE HPA 부하 검증에서 `stock-api`가 2개에서 최대 12개 pod까지 확장되고, GKE node pool도 확장되는 것을 확인했습니다.
- AWS/GCP Router와 OCI Headscale 경로를 통해 AWS RDS 5432 및 Cloud SQL 사설 IP 5432 통신을 검증했습니다.
- AWS RDS -> Cloud SQL DMS 연속 마이그레이션을 CDC 상태로 구성하고 동작을 확인했습니다.
- Route 53 AWS/GCP 상태 검사, calculated health check, CloudWatch 강제 전환 게이트를 구성했습니다. AWS 상태 검사 `health.ilpumjinro.store/healthz`는 HTTP 200을 확인했습니다.
- Failover 워크플로우를 실제 실행해 Cloud SQL 승격, Route 53 GCP 전환, GCP 서비스 HTTPS 응답, Cloud SQL 쓰기를 확인했습니다.
- Failback 워크플로우를 실제 실행해 Cloud SQL -> AWS RDS 역복제 subscription 생성, AWS 쓰기 복구 및 Route 53 AWS 복귀를 확인했습니다.
- Rearm AWS to GCP DMS 워크플로우를 성공시켜 다음 장애 전환을 위한 AWS -> GCP DMS 재구성 자동화를 구현했습니다.
- GCP와 AWS 서비스에 Traffic Origin 배지를 반영했습니다. 현재 브라우저에서 AWS PRIMARY / ap-northeast-2 표시를 확인했습니다.

## 5. 다음 리허설 전 확인할 항목

### 우선 확인

- GCP `Deploy GKE DR Service`의 `Verify the application reads Cloud SQL` 단계가 최근 `127.0.0.1:18080` 연결 실패와 HTTP 504로 대기/실패한 이력이 있습니다. `stock-api`의 실제 readiness/서비스 포트와 Cloud SQL 연결을 확인한 뒤 해당 워크플로우가 성공하는지 재검증해야 합니다.
- Rearm 직후에는 아래 상태를 확인합니다.
  - DMS: `RUNNING`, `CDC`
  - Cloud SQL: `RUNNABLE`, replica 상태이며 `masterInstanceName`이 존재
  - GCP 쓰기 fence: `dr-fence-stock-api-egress` 존재
- 다음 리허설에서는 고유 ticker를 사용해 세 구간 모두를 증명합니다.
  1. 정상 AWS 쓰기 -> Cloud SQL 반영
  2. Failover 중 GCP 쓰기 -> AWS RDS 역복제 반영
  3. Rearm 후 AWS 쓰기 -> 새 Cloud SQL DMS 반영
- `DRTEST0726` 행은 당시 failback의 초기 dump 시점 이후에 추가된 행이므로, 이전 AWS RDS에 없었던 것이 해당 failback 실패를 뜻하지는 않습니다. 다음 리허설에서는 dump 전/후 시점을 명확히 기록합니다.

### 운영 보완

- DR 최소 용량을 spot node pool에만 의존하지 않도록 일반 node pool의 최소 용량을 검토합니다.
- Headscale Router의 Tailnet IP 변경 시 OCI ACL, advertise route 승인, AWS/GCP Router의 accept-routes를 함께 재점검합니다.
- DMS와 Cloud SQL 역할을 외부 CLI로 변경한 뒤에는 Terraform plan을 확인해 의도하지 않은 되돌림이 없는지 검토합니다.
- 리허설 전 RDS 수동 스냅샷을 생성하고, 전환 전/후 화면 및 명령 출력은 증빙으로 보관합니다.

## 6. 상태 확인 명령어

### GKE 접속 및 확장 상태

```bash
gcloud container clusters get-credentials gke-prd-cluster \
  --zone asia-northeast3-a \
  --project ilpoomjinro

kubectl -n stock-demo get hpa
kubectl get nodes -l cloud.google.com/gke-nodepool=spot-node-pool
kubectl -n stock-demo get networkpolicy dr-fence-stock-api-egress
```

### DMS 및 Cloud SQL 상태

```bash
gcloud database-migration migration-jobs describe aws-rds-to-cloudsql-dr \
  --region asia-northeast3 \
  --format='yaml(state,phase,error)'

gcloud sql instances describe dr-standby-postgres \
  --project ilpoomjinro \
  --format='yaml(name,state,masterInstanceName,replicaConfiguration,ipAddresses)'
```

### DNS, 서비스, 전환 게이트 상태

```bash
dig +short ilpumjinro.store @1.1.1.1
curl -sSI https://ilpumjinro.store/

aws cloudwatch describe-alarms \
  --region ap-northeast-2 \
  --alarm-names financial-stock-web-dr-force-failover \
  --query 'MetricAlarms[0].{AlarmName:AlarmName,State:StateValue,Reason:StateReason}' \
  --output table
```

Route 53의 `get-health-check-status`는 calculated health check 상태를 직접 반환하지 않습니다. 계산 상태는 AWS endpoint health check 결과와 CloudWatch alarm 상태를 함께 보고 판단합니다.

### AWS RDS 역복제 상태

```sql
SELECT
  s.subname,
  s.subenabled,
  s.subslotname,
  st.pid,
  st.latest_end_lsn,
  st.latest_end_time
FROM pg_subscription s
LEFT JOIN pg_stat_subscription st ON st.subid = s.oid;
```

`dr_failback_subscription`이 활성화되고 `latest_end_lsn`, `latest_end_time`이 갱신되면 Cloud SQL -> AWS RDS 역복제 연결이 동작 중임을 뜻합니다.

## 7. 시연 권장 순서

1. 정상 화면: 브라우저의 `AWS PRIMARY` 배지, DMS `RUNNING/CDC`, Cloud SQL replica, Route 53/CW 정상 상태를 캡처합니다.
2. Failover: `dr-failover.yml`을 실행하고 GCP DR 배지, public DNS의 GCP IP, Cloud SQL `pg_is_in_recovery() = false`, GCP 테스트 행을 확인합니다.
3. Failback: `dr-failback.yml`을 실행하고 AWS PRIMARY 배지, AWS RDS subscription/테스트 행, Route 53 정상 복귀를 확인합니다.
4. Rearm: `dr-rearm-aws-to-gcp-dms.yml`을 실행하고 DMS `RUNNING/CDC` 및 Cloud SQL replica 상태를 확인합니다.

동일한 전환 워크플로우를 동시에 실행하지 않으며, 실제 promote 또는 failback 전에 반드시 preflight와 쓰기 차단 상태를 확인합니다.