# firewall.tf

# 1. IAP를 통한 SSH 접속 허용 (AWS의 Bastion Host, SSM이랑 유사한 역할)
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "allow-iap-ssh"
  network = google_compute_network.vpc_gcp_prd.name

  # IAP 터널링을 통한 트래픽 허용 (GCP IAP의 고정 IP 대역)
  source_ranges = ["35.235.240.0/20"] 

  allow {
    protocol = "tcp"
    ports    = ["22"] # SSH 포트
  }

  # 이 방화벽 규칙을 적용할 대상 (나중에 VM 생성 시 이 태그를 붙여야 접속 가능)
  target_tags = ["allow-iap-ssh"] 
}

# 2. VPC 내부 통신 허용 (Internal Traffic)
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal-traffic"
  network = google_compute_network.vpc_gcp_prd.name

  # 합의한 VPC 전체 대역 내에서의 통신 허용
  source_ranges = ["10.20.0.0/16", "10.21.0.0/16", "10.22.0.0/20"] # VPC와 서브넷, GKE pod, GKE Service 대역을 모두 포함하는 CIDR 범위로 설정

  allow {
    protocol = "tcp"
    ports    = ["0-65535"] # 모든 포트 허용 (내부망이므로)
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "allow_tailscale" {
  name    = "allow-tailscale-udp"
  network = google_compute_network.vpc_gcp_prd.name
  
  # 전 세계(0.0.0.0/0)를 대상으로 열거나, AWS/오라클 IP만 특정하여 허용, 오라클 IP는 나중에 추가 예정
  source_ranges = ["0.0.0.0/0"] 

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }
  
  target_tags = ["headscale-router"] # VPN VM에 이 태그를 추가하세요.
}
