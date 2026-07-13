# Route 53 GKE DR 전환

## 구성

- AWS Route 53은 `ilpumjinro.store`의 PRIMARY 레코드로 AWS ALB를, SECONDARY 레코드로 GKE DR Gateway의 고정 IP를 사용한다.
- AWS PRIMARY는 AWS ALB의 HTTPS 상태를 30초마다 확인하고, 3회 연속 실패하면 unhealthy로 판단한다.
- GCP SECONDARY는 `gcp.ilpumjinro.store`의 HTTPS 상태를 독립적으로 확인한다.
- GCP Gateway는 `gke-dr-gateway-ip` 고정 외부 IP를 사용한다.
- GCP용 TLS 인증서는 Let's Encrypt DNS-01 방식으로 발급한다. DNS 검증 역할은 `_acme-challenge` TXT 레코드 두 개만 수정할 수 있다.

## 최초 적용 순서

1. AWS Terraform을 apply해 `ilpumjinro-gcp-dr-certificate-role`을 만든다.
2. AWS 출력의 `gcp_dr_certificate_role_arn`을 GCP_sub Secret `AWS_DR_CERTIFICATE_ROLE_ARN`에 등록한다.
3. GCP_sub Secret `LETSENCRYPT_EMAIL`에 인증서 알림을 받을 이메일을 등록한다.
4. GCP `infra-apply-all.yml`에서 `apply_ecc: true`, `apply_gke: false`로 실행해 `gke-dr-gateway-ip`을 예약한다.
5. GCP Actions의 `Ensure GKE DR TLS Certificate`를 실행한다.
6. GCP Actions의 `Deploy GKE DR Service`를 다시 실행해 Gateway에 고정 IP와 HTTPS 리스너를 적용한다.
7. 아래 명령으로 고정 IP를 확인하고 AWS repository Variable `GCP_SERVICE_IP`에 CIDR 없이 등록한다.

```bash
gcloud compute addresses describe gke-dr-gateway-ip \
  --region=asia-northeast3 \
  --project=ilpoomjinro \
  --format='value(address)'
```

8. AWS Terraform `reapply`를 실행해 Route 53 GCP SECONDARY와 `gcp.ilpumjinro.store` 레코드를 반영한다.

## 확인

```bash
curl --resolve gcp.ilpumjinro.store:443:GCP_SERVICE_IP https://gcp.ilpumjinro.store/
aws route53 list-resource-record-sets --hosted-zone-id ROUTE53_ZONE_ID
```

`gcp.ilpumjinro.store`의 HTTPS 요청이 성공하고, Route 53 콘솔에서 AWS/GCP health check가 모두 healthy여야 한다.

## 장애 전환 테스트

Route 53 health check를 disabled로 만들면 항상 healthy가 되므로 사용하면 안 된다. 테스트에서는 PRIMARY health check의 `inverted` 값을 활성화해 AWS가 정상이어도 unhealthy로 보이게 한다. 실제 failover/failback workflow는 다음 단계에서 이 값을 안전 확인 절차와 함께 제어한다.
