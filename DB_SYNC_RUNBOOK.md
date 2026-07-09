# AWS PostgreSQL to GCP Cloud SQL 동기화 준비

이 문서는 AWS `financial-service-db`를 GCP Cloud SQL `dr-standby-postgres`로 지속 동기화하기 위한 작업 메모입니다.

## 지금 코드로 준비한 것

- GCP `datamigration.googleapis.com` API 활성화
- DMS VPC peering connectivity, source/target connection profile, CDC migration job Terraform 리소스 추가
- 기본값은 `enable_dms = false`라서 AWS 원본 DB가 꺼져 있어도 DMS 리소스는 아직 생성하지 않음
- Cloud SQL 대상 인스턴스를 AWS 원본과 맞춰 `POSTGRES_16`으로 정렬하고, 동기화 대상 DB `financial_service`를 추가
- AWS RDS parameter group에 logical replication 관련 파라미터 추가

## AWS DB를 켠 뒤 필요한 작업

1. AWS RDS 파라미터 적용

   Terraform apply 후 `rds.logical_replication`은 재부팅이 필요합니다. RDS를 켠 뒤 planned reboot 또는 maintenance window를 통해 반영합니다.

2. DMS 전용 계정 생성

   AWS RDS `financial_service` DB에 마스터 계정으로 접속한 뒤 실행합니다.

   ```sql
   CREATE USER gcp_dms_user WITH PASSWORD '<DMS_SOURCE_PASSWORD>';
   GRANT rds_replication TO gcp_dms_user;
   GRANT CONNECT ON DATABASE financial_service TO gcp_dms_user;
   GRANT USAGE ON SCHEMA public TO gcp_dms_user;
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO gcp_dms_user;
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO gcp_dms_user;
   ```

3. GitHub Actions 변수/시크릿 설정

   - Repository variable `ENABLE_DMS`: `true`
   - Repository variable `DMS_SOURCE_HOST`: AWS RDS private DNS 또는 GCP에서 도달 가능한 private IP/DNS
   - Repository variable `DMS_SOURCE_USERNAME`: `gcp_dms_user`
   - Repository variable `DMS_DESIRED_STATE`: 처음에는 `NOT_STARTED`
   - Repository secret `DMS_SOURCE_PASSWORD`: 위 SQL에서 지정한 비밀번호

4. Headscale 경로 검증

   GCP DMS VPC peering connectivity가 `vpc-gcp-prd`에 붙은 뒤 AWS RDS의 5432 포트로 도달해야 합니다. 현재 구조에서는 GCP VPC의 AWS 대역 라우트가 `headscale-vpn-server`를 next hop으로 쓰므로, 이 경로가 DMS peering 트래픽에도 유효한지 검증해야 합니다.

5. DMS 작업 시작

   연결 테스트와 migration job validation이 통과하면 `DMS_DESIRED_STATE`를 `RUNNING`으로 바꾸고 `infra-apply-all.yml`을 실행합니다.

## 주의사항

- DMS source password는 Terraform state에 민감값으로 저장될 수 있습니다. 이 저장소는 GCS backend를 사용하므로 state 버킷 접근 권한을 최소화해야 합니다.
- AWS RDS PostgreSQL 16에서 GCP Cloud SQL PostgreSQL 14로 내리는 구성은 호환성 리스크가 큽니다. 대상도 PostgreSQL 16으로 맞추는 것을 기본으로 둡니다.
- 실제 cutover 전까지는 GCP를 standby/read-only 검증 대상으로 보고, 애플리케이션 쓰기 트래픽 전환은 별도 failover 절차에서 처리합니다.
