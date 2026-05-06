# 1. 하이브리드 통신을 위한 Headscale (VPN) 인스턴스
resource "google_compute_instance" "headscale_vpn" {
  name         = "headscale-vpn-server"
  machine_type = "e2-micro" # [Cost Opt] VPN 라우팅만 하므로 아주 작은 사양 사용
  zone         = "asia-northeast3-a"

  # SEC 서브넷에 배치
  network_interface {
    network    = google_compute_network.vpc_gcp_prd.id
    subnetwork = google_compute_subnetwork.subnet_sec.id
    
    # Public IP 부여
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

  # IAP를 통해 VM에 SSH 접속
  tags = ["allow-iap-ssh"]

  # IP 포워딩 활성화 (VPN 라우터 역할을 하기 위해 필수 설정)
  can_ip_forward = true 

  # VM이 켜질 때 자동으로 실행되는 스크립트
  metadata_startup_script = <<-EOF
    #!/bin/bash
    # OS 레벨 패킷 포워딩 켜기 (라우터 필수 설정)
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-custom.conf
    sudo sysctl -p /etc/sysctl.d/99-custom.conf

    # Headscale 클라이언트 설치
    curl -fsSL https://tailscale.com/install.sh | sh

    # SNAT 설정 (GKE Pod가 AWS와 통신할 수 있게 IP를 라우터 IP로 위장)
    iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE

    # 재부팅 시에도 iptables 유지되도록 저장 (iptables-persistent 패키지 필요할 수 있음)
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    netfilter-persistent save
  EOF
}

# GKE -> AWS 통신을 위한 라우팅 테이블
resource "google_compute_route" "route_to_aws" {
  name        = "route-to-aws-via-vpn"
  # AWS VPC의 전체 CIDR 대역을 입력하세요 (예: 10.10.0.0/16)
  dest_range  = "10.10.0.0/16" 
  network     = google_compute_network.vpc_gcp_prd.name #
  
  # 위에서 지정한 AWS 대역으로 가는 트래픽은 이 VPN 인스턴스로 보내라
  next_hop_instance = google_compute_instance.headscale_vpn.id
  next_hop_instance_zone = google_compute_instance.headscale_vpn.zone
  
  priority    = 1000
}
