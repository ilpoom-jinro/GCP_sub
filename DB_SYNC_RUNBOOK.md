# AWS PostgreSQL to GCP Cloud SQL 동기화 준비

이 문서는 AWS `financial-service-db`를 GCP Cloud SQL `dr-standby-postgres`로 지속 동기화하기 위한 작업 메모입니다.

## 지금 코드로 준비한 것

- GCP `datamigration.googleapis.com` API 활성화
- GCP `vpc-gcp-prd`의 Private Services Access peering에서 AWS 정적 경로를 export하도록 구성
- AWS source connection profile Terraform 리소스 추가. 목적지 profile과 migration job은 `gcloud`로 생성
- 기본값은 `enable_dms = false`라서 AWS 원본 DB가 꺼져 있어도 DMS 리소스는 아직 생성하지 않음
- Cloud SQL 대상 인스턴스를 AWS 원본과 맞춰 `POSTGRES_16`으로 정렬
- AWS RDS parameter group에 logical replication 관련 파라미터 추가

## AWS DB를 켠 뒤 필요한 작업

1. AWS RDS 파라미터 적용

   Terraform apply 후 `rds.logical_replication`은 재부팅이 필요합니다. RDS를 켠 뒤 planned reboot 또는 maintenance window를 통해 반영합니다.

2. Cloud SQL 목적지 비우기

   기존 Cloud SQL 인스턴스를 DMS 목적지로 사용하려면 사용자 DB와 사용자 계정이 없어야 합니다. 현재 목적지에는 기본 `postgres` DB와 `postgres` 사용자만 남아 있어야 합니다.

3. DMS 전용 계정 생성

   Amazon RDS PostgreSQL source에는 `pglogical` extension과 해당 extension을 preload하는
   parameter group 설정이 필요합니다. `rds.logical_replication=1`,
   `shared_preload_libraries=pglogical`, `wal_sender_timeout=0`을 적용한 뒤 RDS를
   재부팅합니다.

   DMS는 RDS source 인스턴스의 시스템 DB를 제외한 모든 DB를 확인합니다. 따라서
   `financial_service`와 기본 `postgres` DB에 마스터 계정으로 접속해 필요한 extension과
   권한을 부여합니다. 비밀번호는 GitHub Secret `DMS_SOURCE_PASSWORD`와 동일하게 설정합니다.

   먼저 어느 DB에서든 한 번만 실행합니다.

   ```sql
   CREATE USER gcp_dms_user WITH PASSWORD '<DMS_SOURCE_PASSWORD>';
   GRANT rds_replication TO gcp_dms_user;
   GRANT CONNECT ON DATABASE financial_service TO gcp_dms_user;
   GRANT CONNECT ON DATABASE postgres TO gcp_dms_user;
   ```

   이어서 `financial_service`와 `postgres`에 각각 접속해 실행합니다. 기본 `postgres`
   데이터베이스에 `public` 외 사용자 schema가 없다면 해당 schema 권한은 생략할 수 있습니다.

   ```sql
   -- financial_service와 postgres에서 각각 실행
   CREATE EXTENSION IF NOT EXISTS pglogical;
   GRANT USAGE ON SCHEMA public TO gcp_dms_user;
   GRANT USAGE ON SCHEMA pglogical TO PUBLIC;
   GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO gcp_dms_user;
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO gcp_dms_user;
   GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO gcp_dms_user;
   ALTER DEFAULT PRIVILEGES FOR ROLE financial_admin IN SCHEMA public GRANT SELECT ON TABLES TO gcp_dms_user;
   ALTER DEFAULT PRIVILEGES FOR ROLE financial_admin IN SCHEMA public GRANT SELECT ON SEQUENCES TO gcp_dms_user;
   ```

4. GitHub Actions 변수/시크릿 설정

   - Repository variable `ENABLE_DMS`: `true`
   - Repository variable `DMS_SOURCE_HOST`: AWS RDS private DNS 또는 GCP에서 도달 가능한 private IP/DNS
   - Repository variable `DMS_SOURCE_USERNAME`: `gcp_dms_user`
   - Repository secret `DMS_SOURCE_PASSWORD`: 위 SQL에서 지정한 비밀번호

5. Headscale 경로 검증

   GCP DMS VPC peering connectivity가 `vpc-gcp-prd`에 붙은 뒤 AWS RDS의 5432 포트로 도달해야 합니다. 현재 구조에서는 GCP VPC의 AWS 대역 라우트가 `headscale-vpn-server`를 next hop으로 쓰므로, 이 경로가 DMS peering 트래픽에도 유효한지 검증해야 합니다.

6. DMS 작업 생성 및 시작

   `gcloud database-migration` 또는 DMS Console에서 기존 Cloud SQL 목적지 profile과 continuous migration job을 생성합니다. 목적지 demote와 job test가 통과한 뒤에만 job을 시작합니다.

## 주의사항

- DMS source password는 Terraform state에 민감값으로 저장될 수 있습니다. 이 저장소는 GCS backend를 사용하므로 state 버킷 접근 권한을 최소화해야 합니다.
- AWS RDS PostgreSQL 16에서 GCP Cloud SQL PostgreSQL 14로 내리는 구성은 호환성 리스크가 큽니다. 대상도 PostgreSQL 16으로 맞추는 것을 기본으로 둡니다.
- DMS migration 중에는 목적지 Cloud SQL이 replica 상태가 되므로 `infra/Ecc` Terraform apply를 다시 실행하지 않습니다.
- 실제 cutover 전까지는 GCP를 standby/read-only 검증 대상으로 보고, 애플리케이션 쓰기 트래픽 전환은 별도 failover 절차에서 처리합니다.
