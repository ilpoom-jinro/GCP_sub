# AWS RDS -> GCP Cloud SQL 지속 동기화 작업 기록

## 목적

AWS EKS 서비스의 PostgreSQL RDS를 운영 원본으로 유지하고, 장애 조치에 대비해 GCP Cloud SQL을 대기 DB로 지속 복제한다. 데이터 동기화에는 GCP Database Migration Service(DMS)를 사용하고, AWS와 GCP 간 사설 통신은 OCI의 Headscale 제어 평면과 Tailscale 서브넷 라우터를 통해 구성한다.

## 현재 구성

| 구분 | 리소스 | 값 또는 역할 |
| --- | --- | --- |
| AWS 원본 | RDS | `financial-service-db`, PostgreSQL 16.13 |
| AWS 원본 DB | PostgreSQL DB | `financial_service` |
| GCP 대상 | Cloud SQL | `dr-standby-postgres`, PostgreSQL 16 |
| GCP DMS 소스 프로필 | Connection profile | `aws-postgres-source` |
| GCP DMS 대상 프로필 | Connection profile | `cloudsql-dr-destination` |
| GCP DMS 작업 | Migration job | `aws-rds-to-cloudsql-dr`, 지속 복제 |
| GCP VPC | 네트워크 | `vpc-gcp-prd` |
| AWS 서브넷 라우터 | 현재 Tailscale IP | `100.64.0.9` |
| GCP 서브넷 라우터 | 현재 Tailscale IP | `100.64.0.8` |
| AWS RDS 사설 IP | 현재 확인값 | `10.10.21.54` |
| GCP Private Services Access 대역 | Cloud SQL 사설 서비스 대역 | `10.177.232.0/24` |

IP와 RDS 엔드포인트는 인프라 재생성, 장애 조치, DNS 변경 시 달라질 수 있으므로 실제 작업 전에 다시 확인한다.

## 완료한 작업

### 1. AWS RDS 논리 복제 준비

- RDS parameter group에 논리 복제 관련 설정을 적용했다.
  - `rds.logical_replication = 1`
  - `shared_preload_libraries = pglogical`
  - `wal_sender_timeout = 0`
- RDS를 재부팅했고, 인스턴스 상태 `available`, parameter group 상태 `in-sync`를 확인했다.
- `financial_service`에서 다음을 확인했다.
  - `wal_level = logical`
  - `shared_preload_libraries`에 `pglogical` 포함
  - `pglogical` extension 설치 완료
- DMS 전용 계정 `gcp_dms_user`를 생성했다.
  - `rds_replication` 역할 부여
  - `financial_service`, `postgres`, `template1` 접속 권한 부여
  - `pglogical`, `public` schema의 필요한 조회 권한 부여
- `gcp_dms_user` 비밀번호와 GitHub Secret `DMS_SOURCE_PASSWORD`가 동일한 것을 확인했다.

### 2. GCP Cloud SQL 대상 준비

- 대상 Cloud SQL 인스턴스 `dr-standby-postgres`를 PostgreSQL 16으로 구성했다.
- DMS 대상이 될 수 있도록 사용자 DB와 사용자 계정을 제거했다.
  - 기본 `postgres` DB와 기본 관리자만 남긴 상태를 콘솔에서 확인했다.
- DMS에서 대상을 replica로 전환하기 때문에, DMS가 동작하는 동안 Cloud SQL 설정을 Terraform이 되돌리지 않도록 조치했다.
  - `database.tf`의 `dr_standby_db`에서 `backup_configuration` 변경을 무시하도록 설정했다.
  - read replica에는 백업을 활성화할 수 없기 때문이다.

### 3. Headscale/Tailscale 경로 구성 및 검증

- OCI Headscale에서 다음 서브넷 라우트를 승인했다.
  - AWS 라우터: `10.10.0.0/16`, `10.20.0.0/16`
  - GCP 라우터: `10.50.0.0/16`, `10.52.0.0/16`, `10.53.0.0/20`
- AWS와 GCP 라우터 모두 `tailscale set --accept-routes`를 적용했다.
- GCP 라우터에서 AWS RDS로 향하는 경로가 `tailscale0`을 사용하는 것을 확인했다.
- AWS 라우터에서 Tailscale 대역을 RDS VPC로 전달할 수 있도록 IP forwarding과 NAT를 구성했다.
  - 실제 기본 NIC가 `eth0`이 아닌 `ens5`였으므로, Terraform 스크립트를 기본 라우트의 NIC를 동적으로 찾도록 수정했다.
  - NAT 규칙은 영구 저장했다.
- GCP 라우터에서 AWS RDS `5432` TCP 접속 성공을 확인했다.

### 4. DMS 네트워크 경로 준비

- Private Services Access peering `servicenetworking-googleapis-com`이 활성 상태인 것을 확인했다.
- GCP VPC에서 custom route export가 활성 상태인 것을 확인했다.
- DMS의 PSA 대역 `10.177.232.0/24`에서 GCP Headscale 라우터의 `5432`으로 나가는 방화벽 규칙을 Terraform에 추가하고 적용했다.
- AWS 라우터 `tcpdump`에서 DMS 측 트래픽이 다음 경로로 RDS까지 도달하고 응답하는 것을 확인했다.

```text
10.177.232.x -> GCP Headscale router -> Tailscale -> AWS Headscale router -> 10.10.21.54:5432
```

### 5. DMS 리소스 생성

- GCP DMS API를 활성화했다.
- AWS RDS 소스 연결 프로필 `aws-postgres-source`를 생성했고 상태가 `READY`임을 확인했다.
- Cloud SQL 대상 연결 프로필 `cloudsql-dr-destination`을 생성했고 상태가 `READY`임을 확인했다.
- 지속 복제 작업 `aws-rds-to-cloudsql-dr`을 생성했다.
  - 소스: `aws-postgres-source`
  - 대상: `cloudsql-dr-destination`
  - 데이터베이스 필터: `financial_service`
  - 연결 방식: `vpc-gcp-prd` VPC peering
- DMS가 대상 Cloud SQL을 복제 대상으로 사용할 수 있도록 destination demote를 실행했다.

## 현재 막힌 지점과 원인

최신 DMS 검증은 네트워크와 인증 정보가 아니라 TLS 설정에서 실패했다.

```text
no pg_hba.conf entry for host "10.40.1.65", user "gcp_dms_user",
database "financial_service", no encryption
```

의미는 다음과 같다.

- `10.40.1.65`는 AWS Headscale 라우터의 사설 IP다. DMS 트래픽이 NAT되어 RDS까지 도달했다는 뜻이다.
- 계정과 비밀번호는 통과한 뒤의 단계까지 진행했다.
- RDS가 TLS 없는 PostgreSQL 접속을 거부하고 있다.
- DMS 소스 연결 프로필을 `REQUIRED` TLS 모드로 업데이트해야 한다.

`infra/Ecc`의 Google Provider는 현재 `~> 5.0`이다. 이 버전은 Terraform 설정에서 `postgresql.ssl.type`을 입력값으로 지원하지 않아, 아래처럼 Terraform에 작성하면 에디터 오류와 workflow 실패 가능성이 있다.

```hcl
ssl {
  type = "REQUIRED"
}
```

따라서 현재는 Terraform이 아니라 gcloud CLI로 기존 연결 프로필의 TLS 모드를 적용한다. 전체 Google Provider를 7대로 올리는 작업은 광범위한 Terraform plan 변경 가능성이 있어 별도 검토 대상으로 둔다.

## 다음 작업 순서

### 1. DMS 소스 프로필 TLS 적용

Cloud Shell 또는 gcloud 인증이 된 환경에서 실행한다.

```bash
REGION=asia-northeast3

gcloud database-migration connection-profiles update aws-postgres-source \
  --region="$REGION" \
  --ssl-type=REQUIRED
```

`connection-profiles update` 명령은 `--no-async`를 지원하지 않는다. 해당 옵션을 붙이면 인식할 수 없는 인수 오류가 발생한다.

적용 확인:

```bash
gcloud database-migration connection-profiles describe aws-postgres-source \
  --region="$REGION"
```

출력에서 `ssl`의 `type: REQUIRED`를 확인한다.

### 2. DMS 검증

```bash
gcloud database-migration migration-jobs verify aws-rds-to-cloudsql-dr \
  --region="$REGION"
```

명령이 반환한 operation 이름으로 완료 여부와 상세 오류를 확인한다.

```bash
gcloud database-migration operations describe <OPERATION_ID> \
  --region="$REGION"
```

- `done: true`이고 `error`가 없으면 검증 성공이다.
- `done: false`는 검증 작업이 아직 진행 중이라는 뜻이다. 같은 verify 명령을 반복 실행하지 말고 해당 operation을 조회한다.

### 3. 소스 객체 조회와 작업 시작

검증 성공 후에만 실행한다.

```bash
gcloud database-migration migration-jobs fetch-source-objects aws-rds-to-cloudsql-dr \
  --region="$REGION"

gcloud database-migration migration-jobs start aws-rds-to-cloudsql-dr \
  --region="$REGION"
```

각 명령이 반환하는 operation을 조회하여 오류 없이 완료되는지 확인한다.

### 4. 초기 적재 및 지속 복제 검증

- DMS 콘솔에서 migration job 상태가 실행 중인지 확인한다.
- Cloud SQL 대상에서 `financial_service` DB, 테이블, 초기 데이터가 생성됐는지 확인한다.
- AWS 원본에 테스트 레코드를 한 건 작성하고 대상에 반영되는지 확인한다.
- 테스트 데이터는 검증 후 제거하거나, 별도 테스트 테이블에서만 수행한다.
- 복제 지연과 DMS 오류 로그를 확인한다.

## AWS 장애 조치와 AWS 복귀(failback) 설계

### 동작 원칙

- 현재 DMS 작업은 AWS RDS에서 Cloud SQL로만 데이터를 전송하는 단방향 복제다.
- AWS 장애 시 Cloud SQL을 promote하면 해당 DMS 작업은 AWS와 연결이 끊기며 완료된다.
- AWS와 GCP 양쪽에서 동시에 쓰기를 허용하면 데이터 충돌을 자동으로 해결할 수 없다. 어느 시점에도 쓰기 원본은 한 곳만 유지한다.
- GCP DMS는 PostgreSQL Cloud SQL에서 AWS RDS로 역방향 복제하는 기능을 제공하지 않는다. AWS 복구 후에는 Cloud SQL을 발행자, AWS RDS를 구독자로 하는 PostgreSQL 논리 복제를 별도로 구성한다.

### AWS 장애 시 failover 절차

1. AWS 애플리케이션과 RDS의 쓰기 경로를 중지하거나, AWS 장애로 더 이상 쓰기가 불가능한지 확인한다.
2. DMS 콘솔에서 복제 지연을 확인한다. 계획된 전환이라면 지연이 0이 될 때까지 기다린다.
3. `aws-rds-to-cloudsql-dr` migration job을 promote한다.
4. promote 완료 후 Cloud SQL이 독립 primary가 된 것을 확인한다.
5. 애플리케이션의 DB 연결을 Cloud SQL로 전환하고, 이 시점부터 GCP만 쓰기 원본으로 사용한다.

### AWS 복구 후 failback 절차

1. 복구된 AWS RDS를 애플리케이션 트래픽에서 분리한다. 이 시점에는 AWS에 쓰기를 절대 허용하지 않는다.
2. AWS RDS를 GCP 원본과 동일한 schema와 데이터 상태로 재초기화한다. 장애 전의 오래된 데이터를 그대로 둔 RDS에 양방향 복제를 연결하면 안 된다.
3. Cloud SQL의 `cloudsql.logical_decoding=on` 설정을 확인한다. 현재 Terraform으로 이미 관리 중이며, native PostgreSQL 논리 복제에는 `pglogical` 플래그가 필요하지 않다.
4. OCI Headscale에 Cloud SQL Private Services Access 대역 `10.177.232.0/24`을 GCP 서브넷 라우터의 advertised route로 승인한다.
5. Headscale ACL에 AWS 라우터에서 GCP PSA 대역의 PostgreSQL 포트로 가는 규칙을 추가한다.
6. AWS Headscale Router에 TCP proxy를 구성한다. AWS RDS의 PostgreSQL subscription은 VPC4 Router의 사설 IP와 proxy 포트로 접속하고, proxy가 Tailscale을 거쳐 Cloud SQL `5432`으로 전달한다.
7. Cloud SQL에서 native publication을 만들고, AWS RDS에서 native subscription을 만든다. RDS가 구독자로 GCP의 변경을 수신하도록 구성한다.
8. Cloud SQL publisher와 AWS RDS subscriber의 복제 지연이 0인지 확인한다.
9. GCP 애플리케이션 쓰기를 중지하고 AWS subscription을 비활성화한다.
10. 애플리케이션 DB 연결을 AWS RDS로 전환한다.
11. 다음 DR 주기를 위해 새 AWS RDS -> Cloud SQL DMS migration job을 생성하고 시작한다.

### 금지 사항

- Cloud SQL을 promote하기 전 GCP에 쓰기 트래픽을 보내지 않는다.
- GCP와 AWS에 동시에 쓰기를 허용하지 않는다.
- DMS가 완료된 뒤 기존 migration job을 역방향으로 재사용하려 하지 않는다.

## 운영 주의사항

- DMS 작업이 실행 중인 Cloud SQL 대상은 replica 상태다. 대상에 쓰기 작업을 하면 안 된다.
- DMS 대상 Cloud SQL에 대해 `infra/Ecc` Terraform apply를 무심코 실행하지 않는다. 특히 replica가 된 대상의 백업 설정을 Terraform이 변경하려 하면 오류가 발생할 수 있다.
- AWS RDS 재생성 또는 private IP 변경 시 다음을 다시 확인한다.
  - DMS source profile의 호스트
  - AWS 보안 그룹의 5432 허용 범위
  - Headscale route 승인 상태
  - AWS 라우터 NAT 규칙과 기본 NIC
- `DMS_SOURCE_PASSWORD`는 Terraform state와 GitHub Secrets에 노출될 수 있는 민감 정보다. 비밀번호를 회전하면 RDS 계정과 GitHub Secret, DMS source profile을 함께 갱신한다.
- 실제 장애 조치 전까지 GCP는 standby/read-only로 취급한다. 애플리케이션 트래픽 전환, 쓰기 재개, 원복 절차는 별도의 failover runbook으로 관리한다.

## 자동화 스크립트

`scripts/dr`에는 장애 조치에 필요한 상태 조회와 승인 절차를 스크립트로 정리했다.

```bash
scripts/dr/status.sh
scripts/dr/failover-to-gcp.sh
```

`failover-to-gcp.sh`는 기본적으로 사전 점검만 한다. 실제 promote는 AWS의 애플리케이션과 RDS 쓰기 차단을 완료한 뒤 아래처럼 명시적으로 실행한다.

```bash
scripts/dr/failover-to-gcp.sh --execute --aws-writes-fenced --confirm PROMOTE_CLOUDSQL_DR
```

GitHub Actions에서 실행할 때는 `Promote GCP DR Database` 워크플로를 사용한다. 상세한
승격 조건과 입력값은 [DB_FAILOVER_AUTOMATION.md](DB_FAILOVER_AUTOMATION.md)를 참고한다.

AWS 복귀는 복구된 RDS를 초기화하고 역방향 네트워크 경로와 native logical replication을 구성해야 한다. 현재는 다음 스크립트가 해당 선행 조건만 확인한다.

```bash
scripts/dr/failback-preflight.sh
```

AWS Router TCP proxy, Headscale PSA route 승인, Cloud SQL 사설 IP 설정 및 통신 검증은 [DB_FAILBACK_NETWORK.md](DB_FAILBACK_NETWORK.md)를 따른다. GitHub Actions에서는 `Check GCP DR DB Failback Readiness` 워크플로로 Cloud SQL 측의 읽기 전용 사전 점검을 실행할 수 있다.
