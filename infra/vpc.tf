# 1. VPC 생성 (자동 생성 서브넷 비활성화)
resource "google_compute_network" "vpc_gcp_prd" {
  name                    = "vpc-gcp-prd"
  auto_create_subnetworks = false 
  routing_mode            = "GLOBAL"
}

# 2. web tier 서브넷 (WEB)
resource "google_compute_subnetwork" "subnet_web" {
  name          = "subnet-web"
  network       = google_compute_network.vpc_gcp_prd.id
  region        = "asia-northeast3"
  ip_cidr_range = "10.20.1.0/24" # 256개 IP
  
  private_ip_google_access = true # 공인 ip 없이도 구글 내부 API (GCS 버킷 등) 접근 허용
}

# 3. GKE 전용 서브넷 (WAS) - 상준님 작업 공간
resource "google_compute_subnetwork" "subnet_was_gke" {
  name          = "subnet-was-gke"
  network       = google_compute_network.vpc_gcp_prd.id
  region        = "asia-northeast3"
  
  # Primary Range (GKE 노드용)
  ip_cidr_range = "10.20.2.0/24" 

  # Secondary Range 1 (GKE Pod용)
  secondary_ip_range {
    range_name    = "gke-pod-range"
    ip_cidr_range = "10.21.0.0/16" 
  }

  # Secondary Range 2 (GKE Service용)
  secondary_ip_range {
    range_name    = "gke-svc-range"
    ip_cidr_range = "10.22.0.0/20" 
  }

  private_ip_google_access = true
}

# 4. DB 서브넷
resource "google_compute_subnetwork" "subnet_db" {
  name          = "subnet-db"
  network       = google_compute_network.vpc_gcp_prd.id
  region        = "asia-northeast3"
  ip_cidr_range = "10.20.3.0/24" 
  private_ip_google_access = true
}

# 5. 보안(headscale router 배치용) 서브넷
resource "google_compute_subnetwork" "subnet_sec" {
  name          = "subnet-sec"
  network       = google_compute_network.vpc_gcp_prd.id
  region        = "asia-northeast3"
  ip_cidr_range = "10.20.4.0/24" 
  private_ip_google_access = true
}