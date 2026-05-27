# 0. Headscale VPN용 고정 공인 IP 생성 (지역: 서울)
resource "google_compute_address" "vpn_static_ip" {
  name   = "headscale-vpn-static-ip"
  region = "asia-northeast3"
}

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
      nat_ip         = google_compute_address.vpn_static_ip.address
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
  tags = ["allow-iap-ssh", "headscale-router"]

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
    # mtu 문제 방지 위해 TCP MSS 조정 (VPN 통신 안정성 향상, 패킷이 커져도 MTU에 맞게 조정)
    iptables -t mangle -A FORWARD -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # 재부팅 시에도 iptables 유지되도록 저장 (iptables-persistent 패키지 필요할 수 있음)
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    netfilter-persistent save

    # tailscale 실행 커맨드 추가 예정
    # --advertise-routes: GCP의 서브넷 대역을 다른 노드(AWS 등)에 알림 
    # --snat-subnet-routes=false: Tailscale 자체 SNAT를 끄고, 우리가 설정한 iptables SNAT를 사용
    tailscale up --login-server https://headscale.ilpumjinro.cloud/ --authkey hskey-auth-E_TSfOTrO6Mc-f_7zjnNVIcsTyRf1ts6NRV3VwJm5r2nnH8f-KmwH6w_U7x6Sj8WmDeAqjl5NfK-x --advertise-routes=10.50.0.0/16,10.51.0.0/16,10.52.0.0/20 --snat-subnet-routes=false

  EOF
}

# GKE -> AWS 통신을 위한 라우팅 테이블
resource "google_compute_route" "route_to_aws" {
  for_each = toset(["10.10.0.0/16", "10.20.0.0/16", "10.30.0.0/16", "10.40.0.0/16"])

  # route-to-aws-10-10, route-to-aws-10-20 식으로 이름이 자동 생성됨
  name        = "route-to-aws-${replace(each.value, "/[./]/", "-")}"
  dest_range  = each.value
  network     = google_compute_network.vpc_gcp_prd.name
  
  next_hop_instance = google_compute_instance.headscale_vpn.id
  next_hop_instance_zone = google_compute_instance.headscale_vpn.zone
  
  priority    = 1000
}
