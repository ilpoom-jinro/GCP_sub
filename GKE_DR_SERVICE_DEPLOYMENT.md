# GKE DR 서비스 배포

AWS 서비스 EKS의 stock-demo 이미지를 GCP Artifact Registry로 복제하고, GKE의 `stock-demo` 네임스페이스에 같은 frontend와 backend를 배포한다.

## 사전 조건

1. `infra/Ecc` apply로 Artifact Registry `dr-app`을 생성한다.
2. GCP_sub GitHub repository에 다음 값을 등록한다.
   - Secret `AWS_DR_IMAGE_MIRROR_ROLE_ARN`: AWS에서 생성한 GCP_sub 전용 ECR 읽기 역할 ARN
   - Secret `AWS_REGION`: `ap-northeast-2`
   - Secret `WIF_PROVIDER`, `TF_SA_EMAIL`: 기존 GCP 인증 값
   - Secret `GCP_DR_DB_USER`, `GCP_DR_DB_PASSWORD`: Cloud SQL에 접속할 애플리케이션 계정
   - Variable `GCP_DR_DB_HOST`: Cloud SQL private IP 또는 내부 DNS 이름
3. GCP 인증 서비스 계정에는 Artifact Registry 쓰기, GKE 배포 권한이 필요하다.
4. AWS ECR에 `financial/demo-app-backend`와 `financial/demo-app-frontend`의 동일 태그가 존재해야 한다.

## 실행

GitHub Actions의 `Deploy GKE DR Service` workflow를 실행하고, AWS에 배포된 이미지 태그를 입력한다. 기본값 `latest`는 테스트용이며, 운영 전환에는 AWS 배포 workflow가 만든 날짜-커밋 SHA 태그를 사용한다.

워크플로우는 다음을 수행한다.

1. AWS ECR 로그인 후 backend/frontend 이미지를 GCP Artifact Registry에 복제한다.
2. GitHub Secret의 DB 접속 정보로 GKE Secret `stock-api-db`를 생성 또는 갱신한다.
3. GKE에 frontend, backend, Istio Gateway를 적용한다.
4. 두 Deployment의 rollout 완료 여부와 Cloud SQL 읽기 연결을 확인한다.
5. 마지막으로 `stock-api`의 모든 egress를 막는 `dr-fence-stock-api-egress`
   NetworkPolicy를 적용한다. 따라서 standby Cloud SQL에는 애플리케이션 쓰기뿐 아니라
   애플리케이션 DB 접근 자체가 허용되지 않는다.

## 주의사항

- 이 단계의 Gateway는 HTTP LoadBalancer로 GCP 직접 접속을 먼저 검증하기 위한 구성이다. Route 53 failover에 연결하기 전 HTTPS 인증서와 고정 외부 IP를 다음 단계에서 추가한다.
- Cloud SQL이 DMS standby인 동안에는 GCP를 읽기 검증 용도로만 사용한다. 배포 workflow가
  `stock-api` egress를 차단하므로 Cloud SQL promote 완료 전까지 GCP API가 DB를 읽거나
  쓸 수 없다. `DR Failover to GCP` workflow만 promote 성공 후 이 정책을 제거한다.
- DB 비밀번호를 Git에 저장하지 않는다. workflow가 GitHub Secret을 Kubernetes Secret으로 전달한다.
