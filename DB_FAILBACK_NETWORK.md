# DB Failback 네트워크 경로

이 문서는 AWS 장애 조치 후 GCP Cloud SQL의 데이터를 AWS RDS로 되돌릴 때 사용할 네트워크 경로를 설명합니다. 이 경로는 Cloud SQL을 publisher, AWS RDS를 subscriber로 사용하는 PostgreSQL native logical replication 전용입니다.

## 구성

```text
AWS RDS (subscriber)
  -> AWS VPC4 Headscale Router:15432
  -> Tailscale / OCI Headscale
  -> GCP Headscale Router
  -> Cloud SQL private IP:5432 (publisher)
```

- AWS 라우터의 `15432` 포트는 VPC1 `10.10.0.0/16`에서만 접근할 수 있습니다.
- AWS 라우터의 `socat` 프록시는 Cloud SQL 사설 IP의 `5432`으로만 전달합니다.
- GCP 라우터는 Cloud SQL Private Services Access(PSA) 대역을 광고합니다.
- GCP 라우터는 `100.64.0.0/10`의 복제 트래픽을 VPC 사설 NIC로 SNAT해 Cloud SQL의 응답 경로를 보장합니다.

## 사전 조건

1. 실제 failback 전까지 AWS RDS에는 애플리케이션 쓰기를 허용하지 않습니다.
2. Cloud SQL이 DMS promote를 마친 독립 primary여야 합니다.
3. `cloudsql.logical_decoding=on`이 유지되어야 합니다.
4. AWS RDS는 Cloud SQL과 같은 스키마와 데이터 기준점으로 재초기화되어야 합니다. 오래된 RDS 데이터 위에 subscription을 바로 만들면 안 됩니다.

## Terraform 적용 순서

### 1. Cloud SQL 사설 IP 확인

GCP 리포지토리 `infra/Ecc`에서 apply가 끝난 뒤 다음 중 하나로 확인합니다.

```bash
terraform output -raw dr_standby_private_ip

gcloud sql instances describe dr-standby-postgres \
  --project=ilpoomjinro \
  --format='value(ipAddresses[?type="PRIVATE"].ipAddress)'
```

### 2. AWS GitHub Actions Variable 등록

AWS 리포지토리의 Actions Variable에 아래 값을 등록합니다.

| 이름 | 값 |
| --- | --- |
| `GCP_CLOUDSQL_PRIVATE_IP` | 앞 단계에서 확인한 Cloud SQL 사설 IP |

AWS `Terraform operations`의 `reapply`를 실행합니다. 이 작업은 AWS Headscale Router에 `cloudsql-failback-proxy` systemd 서비스를 설치합니다.

서비스 확인은 AWS Router의 SSM Session Manager에서 수행합니다.

```bash
sudo systemctl status cloudsql-failback-proxy --no-pager
sudo ss -lntp | grep ':15432'
```

### 3. GCP 라우터 설정 반영

GCP `infra/Ecc` apply로 startup script가 갱신됩니다. 이미 실행 중인 VM은 metadata 변경만으로 startup script를 다시 실행하지 않으므로, 계획된 유지보수 시간에 GCP Headscale Router를 재시작하거나 아래 명령을 VM에서 한 번 실행합니다.

```bash
PSA_CIDR=10.177.232.0/24
PRIMARY_INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')

sudo iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -o "$PRIMARY_INTERFACE" -j MASQUERADE 2>/dev/null || \
  sudo iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -o "$PRIMARY_INTERFACE" -j MASQUERADE
sudo netfilter-persistent save
sudo tailscale set --advertise-routes=10.50.0.0/16,10.52.0.0/16,10.53.0.0/20,"$PSA_CIDR"
```

### 4. OCI Headscale route와 ACL 승인

OCI Headscale 서버에서 GCP router node ID를 확인한 뒤 PSA route를 승인합니다.

```bash
sudo headscale nodes list-routes
sudo headscale nodes approve-routes --identifier <GCP_ROUTER_NODE_ID> --routes 10.50.0.0/16,10.52.0.0/16,10.53.0.0/20,10.177.232.0/24
```

정책 파일의 기존 `acls` 배열에 다음 규칙을 추가하고 Headscale 서비스를 재시작합니다. AWS 라우터의 현재 Tailscale IP는 재등록 시 달라질 수 있으므로 먼저 `sudo tailscale ip -4`로 실제 값을 확인해 바꿉니다.

```json
{
  "action": "accept",
  "src": ["100.64.0.9"],
  "dst": ["10.177.232.0/24:5432"]
}
```

Headscale은 서브넷 route를 node와 control plane 양쪽에서 승인해야 합니다. route 승인 방법은 [Headscale route 문서](https://headscale.net/stable/ref/routes/)를 따릅니다.

### 5. 통신 검증

AWS Router의 SSM Session Manager에서 Cloud SQL까지의 upstream 연결을 확인합니다.

```bash
CLOUDSQL_IP=<GCP_CLOUDSQL_PRIVATE_IP>
timeout 5 bash -c "</dev/tcp/$CLOUDSQL_IP/5432" && echo "Cloud SQL reachable"
```

그 다음 VPC1 내부에서 AWS Router 사설 IP의 proxy 포트를 확인합니다.

```bash
AWS_ROUTER_IP=<AWS_HEADSCALE_ROUTER_PRIVATE_IP>
timeout 5 bash -c "</dev/tcp/$AWS_ROUTER_IP/15432" && echo "Failback proxy reachable"
```

두 검증이 성공해도 아직 데이터 복제는 시작되지 않습니다. AWS Terraform `reapply`는 Router에 PostgreSQL 16 client와 `/usr/local/sbin/cloudsql-reverse-replication` 실행기를 배포합니다.

## 역복제 실행기

이 실행기는 AWS Router에서 Cloud SQL을 덤프해 AWS RDS를 기준점부터 재구성하고, Cloud SQL publication과 AWS RDS subscription을 생성합니다. 기본 실행은 읽기 전용 점검이며, 실제 데이터 변경에는 명시적 확인 인자가 필요합니다.

AWS Router의 SSM Session Manager에서 아래 환경 변수를 현재 비밀번호로 설정한 뒤 점검을 실행합니다. 비밀번호는 명령 출력이나 GitHub Actions 로그에 남기지 마십시오.

```bash
export CLOUDSQL_ADMIN_USER=postgres
export CLOUDSQL_ADMIN_PASSWORD='<Cloud SQL postgres password>'
export RDS_HOST='financial-service-db.<endpoint>.rds.amazonaws.com'
export RDS_ADMIN_USER=financial_admin
export RDS_ADMIN_PASSWORD='<AWS RDS administrator password>'
export FAILBACK_PROXY_HOST='<AWS Router private IP>'
export REPLICATION_PASSWORD='<new dedicated Cloud SQL replication password>'

sudo -E cloudsql-reverse-replication
```

Cloud SQL이 유일한 쓰기 원본이고 AWS 애플리케이션 및 RDS 쓰기를 완전히 차단했으며, AWS RDS 데이터를 Cloud SQL 기준으로 교체해도 될 때만 실행합니다.

```bash
sudo -E cloudsql-reverse-replication \
  --execute \
  --gcp-writes-fenced \
  --rebuild-rds-from-cloudsql \
  --terminate-rds-sessions \
  --confirm CREATE_REVERSE_REPLICATION
```

성공하면 Cloud SQL publisher slot 지연이 `65536` bytes 이하가 될 때까지 대기합니다. 이 상태에서 GCP 쓰기를 차단하고 `DR Failback to AWS` 워크플로를 실행해 Route 53을 AWS로 돌립니다.

## 보안 원칙

- `15432`는 failback 목적의 내부 프록시 포트이며 인터넷에 공개하지 않습니다.
- Cloud SQL private IP와 Tailscale CGNAT 대역의 광범위한 허용 규칙을 추가하지 않습니다.
- Cloud SQL과 AWS RDS에서 동시에 쓰기를 허용하지 않습니다.
