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
  source_ranges = ["10.20.0.0/16"]

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