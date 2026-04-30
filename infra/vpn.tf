# 1. 하이브리드 통신을 위한 Headscale (VPN) 인스턴스
resource "google_compute_instance" "headscale_vpn" {
  name         = "headscale-vpn-server"
  machine_type = "e2-micro" # [Cost Opt] VPN 라우팅만 하므로 아주 작은 사양 사용
  zone         = "asia-northeast3-a"

  # SEC 서브넷에 배치
  network_interface {
    network    = google_compute_network.vpc_gcp_prd.id
    subnetwork = google_compute_subnetwork.subnet_sec.id
    
    # Public IP 부여 (온프레미스 노트북이 클라우드 VPN으로 찾아오기 위해 필수)
    access_config {
      network_tier = "PREMIUM"
    }
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 20
    }
  }

  # ★ 바로 이곳입니다! 이 태그 덕분에 IAP를 통해 이 VM에 안전하게 SSH 접속이 가능해집니다.
  tags = ["allow-iap-ssh"]

  # IP 포워딩 활성화 (VPN 라우터 역할을 하기 위해 필수 설정)
  can_ip_forward = true 

  # ★ [추가됨] VM이 켜질 때 자동으로 실행되는 스크립트
  metadata_startup_script = <<-EOF
    #!/bin/bash
    # OS 레벨 패킷 포워딩 켜기 (라우터 필수 설정)
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-custom.conf
    sudo sysctl -p /etc/sysctl.d/99-custom.conf

    # Headscale 클라이언트 설치 (수동 설치의 번거로움 제거)
    curl -fsSL https://tailscale.com/install.sh | sh
  EOF
}

# ★ [핵심 추가 리소스] GKE -> AWS 통신을 위한 라우팅 테이블
resource "google_compute_route" "route_to_aws" {
  name        = "route-to-aws-via-vpn"
  # AWS VPC의 전체 CIDR 대역을 입력하세요 (예: 10.10.0.0/16)
  dest_range  = "10.10.0.0/16" 
  network     = google_compute_network.vpc_gcp_prd.name #
  
  # 위에서 지정한 AWS 대역으로 가는 트래픽은 이 VPN 인스턴스로 보내라!
  next_hop_instance = google_compute_instance.headscale_vpn.id
  next_hop_instance_zone = google_compute_instance.headscale_vpn.zone
  
  priority    = 1000
}
