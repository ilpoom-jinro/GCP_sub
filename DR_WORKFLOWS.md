# DR 통합 워크플로

## 사전 설정

AWS Terraform을 적용한 뒤 다음 output을 확인한다.

```bash
terraform output -raw gcp_dr_route53_failover_role_arn
```

출력값을 GCP_sub repository secret `AWS_DR_ROUTE53_ROLE_ARN`에 등록한다. 이 역할은
Route 53 상태 검사를 조회하고 반전하는 권한만 가지며 DNS 레코드나 다른 AWS 리소스는
수정할 수 없다.

## DR Failover to GCP

평상시에는 `mode: preflight`로 실행한다. 다음 항목을 변경 없이 확인한다.

- GCP 서비스 HTTPS 응답
- DMS `RUNNING / CDC`
- Cloud SQL `RUNNABLE`
- Route 53 AWS PRIMARY 상태

실제 장애 전환 또는 계획된 테스트에서는 AWS 애플리케이션과 RDS 쓰기를 먼저 차단한
뒤 아래 입력으로 실행한다.

| 입력 | 값 |
| --- | --- |
| `mode` | `failover` |
| `aws_writes_fenced` | `true` |
| `confirmation` | `FAILOVER_TO_GCP` |

워크플로는 Cloud SQL을 먼저 promote한 뒤, AWS PRIMARY가 정상인 계획 테스트에서는
health check를 반전시켜 Route 53 트래픽을 GCP SECONDARY로 전환한다. AWS PRIMARY가
이미 비정상이면 자연 failover 상태를 유지하고 반전하지 않는다. Cloud SQL promote는
기존 AWS -> GCP DMS 스트림을 영구 종료하므로 단순 UI 테스트 목적으로 실행하면 안 된다.

## DR Failback to AWS

이 워크플로는 역복제를 만들거나 RDS를 초기화하지 않는다. 먼저 다음 작업을 완료한다.

1. 복구된 RDS를 서비스 트래픽에서 분리하고 Cloud SQL 기준으로 재초기화한다.
2. Cloud SQL publication과 RDS subscription을 구성한다.
3. 역복제 지연이 0이 될 때까지 기다린다.
4. GCP 애플리케이션과 Cloud SQL 쓰기를 차단한다.

그 다음 아래 입력으로 실행한다.

| 입력 | 값 |
| --- | --- |
| `mode` | `failback` |
| `reverse_replication_caught_up` | `true` |
| `gcp_writes_fenced` | `true` |
| `confirmation` | `FAILBACK_TO_AWS` |

워크플로는 AWS 직접 서비스가 정상인지 확인하고 Route 53 health check 반전을 해제한다.
실제 AWS 상태 검사가 정상일 때만 루트 도메인이 AWS PRIMARY로 복귀한다. GCP HPA와
클러스터 autoscaler는 트래픽 감소 후 설정된 최소 replica와 node 수로 축소한다.

## 소유권과 주의사항

- Route 53 health check의 `inverted` 값은 DR 워크플로가 소유한다. Terraform은 이 필드의
  변경을 무시하므로 장애 중 일반 apply가 의도치 않게 AWS로 복귀시키지 않는다.
- `production` environment에 required reviewer를 설정해 실제 전환 전에 승인을 받는다.
- 두 통합 워크플로는 같은 concurrency group을 사용하므로 동시에 실행되지 않는다.
- failback 뒤 다음 DR 주기를 위해 새 AWS -> GCP DMS 작업을 구축해야 한다.
