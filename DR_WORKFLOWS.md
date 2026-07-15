# DR 통합 워크플로

## 사전 설정

AWS Terraform을 적용한 뒤 다음 output을 확인한다.

```bash
terraform output -raw gcp_dr_route53_failover_role_arn
terraform output -raw vpc4_headscale_router_instance_id
```

출력값을 GCP_sub repository secret `AWS_DR_ROUTE53_ROLE_ARN`에 등록한다. 이 역할은
Route 53 상태 검사와 테스트용 CloudWatch 게이트를 조회하고, 전용 CodeBuild 프로젝트
`financial-service-dr-write-fence`와 Router의 고정 역복제 SSM 문서만 실행할 수 있다.
두 번째 output은 repository variable `AWS_DR_ROUTER_INSTANCE_ID`에 등록한다. DNS 레코드나
다른 AWS 리소스는 수정할 수 없다.

GCP_sub repository secret에는 아래 두 값도 필요하다.

- `GCP_DR_DB_USER`: Cloud SQL 관리자 사용자명(기본값 `postgres`)
- `GCP_DR_DB_PASSWORD`: 해당 Cloud SQL 관리자 비밀번호

실제 failback을 실행할 때 워크플로는 이 두 값을 AWS의 전용 Secrets Manager 시크릿으로
한 번만 전달합니다. 값 자체는 GitHub Actions 로그, SSM 명령 인자, Terraform state에 남지 않습니다.

## DR Failover to GCP

평상시에는 `mode: preflight`로 실행한다. 다음 항목을 변경 없이 확인한다.

- GCP 서비스 HTTPS 응답
- DMS `RUNNING / CDC`
- Cloud SQL `RUNNABLE`
- Route 53 AWS PRIMARY 상태

평상시 `Deploy GKE DR Service`는 `stock-api`의 egress를 차단하는
`dr-fence-stock-api-egress` NetworkPolicy를 적용한다. 따라서 GCP 워크로드는 warm
standby로 유지되지만 DMS replica인 Cloud SQL에는 접근할 수 없다.

실제 장애 전환 또는 계획된 테스트에서는 워크플로가 AWS Service EKS 내부의 전용
CodeBuild 작업을 실행해 `stock-api`의 RDS 5432 egress를 차단한다. DMS 트래픽은
애플리케이션 Pod와 분리되어 있으므로 이 차단의 영향을 받지 않는다.

| 입력 | 값 |
| --- | --- |
| `mode` | `failover` |
| `aws_write_fence_mode` | `automated` |
| `confirmation` | `FAILOVER_TO_GCP` |

AWS 자체가 이미 접근 불가능해 CodeBuild를 실행할 수 없는 실제 장애에서는
`aws_write_fence_mode: already-unavailable`과 `aws_writes_fenced: true`를 함께 사용한다.

워크플로는 Cloud SQL을 먼저 promote하고, promote 성공을 확인한 뒤에만 GCP의
`dr-fence-stock-api-egress` 정책을 제거하고 API의 Cloud SQL 읽기 연결을 확인한다.
그 다음 계획 테스트에서는 테스트용 CloudWatch metric을 장애 값으로 기록해 Route 53 트래픽을
GCP SECONDARY로 전환한다. 실제 AWS PRIMARY가 이미 비정상이면 endpoint 상태 검사도
동일하게 failover에 반영된다. Cloud SQL promote는
기존 AWS -> GCP DMS 스트림을 영구 종료하므로 단순 UI 테스트 목적으로 실행하면 안 된다.

## DR Failback to AWS

실제 `failback` 모드는 GCP 애플리케이션 쓰기를 차단한 후 Cloud SQL 데이터를 기준으로
RDS를 재구축하고, Cloud SQL publication과 RDS subscription을 생성합니다. publisher slot
lag가 정확히 `0 byte`가 될 때만 AWS 쓰기를 다시 열고 Route 53을 AWS로 복귀시킵니다.
RDS의 기존 `financial_service` 데이터는 Cloud SQL 기준으로 교체됩니다.

실행 입력은 아래와 같습니다.

| 입력 | 값 |
| --- | --- |
| `mode` | `failback` |
| `gcp_write_fence_mode` | `automated` |
| `confirmation` | `FAILBACK_TO_AWS` |

`automated` 모드에서 워크플로는 `stock-demo/stock-api`에 egress가 없는
`NetworkPolicy`를 적용해 Cloud SQL을 포함한 외부 쓰기 경로를 차단한다. 다음 failover
실행은 이 임시 정책을 먼저 삭제해 GCP 서비스의 Cloud SQL 접근을 복구한다. GKE 자체가
이미 접근 불가능한 실제 장애에서는 `gcp_write_fence_mode: already-unavailable`과
`gcp_writes_fenced: true`를 함께 사용한다.

워크플로는 AWS 직접 서비스가 정상인지 확인하고, 역복제 완료 후 AWS EKS의 RDS egress
차단을 해제한 뒤 테스트용 CloudWatch metric을 정상 값으로 되돌린다. 실제 AWS 상태 검사가 정상일 때만
루트 도메인이 AWS PRIMARY로 복귀한다. GCP HPA와 클러스터 autoscaler는 트래픽 감소 후
설정된 최소 replica와 node 수로 축소한다.

## 소유권과 주의사항

- AWS PRIMARY 라우팅은 실제 `/healthz` 상태 검사와 테스트용 CloudWatch 게이트를 함께 보는
  calculated health check가 결정한다. 테스트 게이트만 조작하므로 실제 상태 검사 설정은 변경하지 않는다.
- `production` environment에 required reviewer를 설정해 실제 전환 전에 승인을 받는다.
- 두 통합 워크플로는 같은 concurrency group을 사용하므로 동시에 실행되지 않는다.
- failback 뒤 다음 DR 주기를 위해 새 AWS -> GCP DMS 작업을 구축해야 한다.
