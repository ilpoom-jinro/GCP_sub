# network.tf

# 1. Cloud Router 생성 (NAT가 올라갈 논리적 기반)
resource "google_compute_router" "prd_router" {
  name    = "prd-cloud-router"
  region  = "asia-northeast3" # 서울 리전
  network = google_compute_network.vpc_gcp_prd.id

  # BGP 설정은 VPN 통신 고도화 시 필요할 수 있으나 현재는 NAT용으로만 사용
}

# 2. Cloud NAT 생성
resource "google_compute_router_nat" "prd_nat" {
  name   = "prd-cloud-nat"
  router = google_compute_router.prd_router.name
  region = google_compute_router.prd_router.region

  # NAT IP를 구글이 알아서 동적으로 할당하고 관리하게 만듭니다.
  nat_ip_allocate_option = "AUTO_ONLY"

  # VPC 내의 모든 서브넷(WAS, SEC 등)이 인터넷으로 나갈 때 이 NAT를 타도록 허용
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY" # 비용 절감을 위해 에러 로그만 남깁니다.
  }
}