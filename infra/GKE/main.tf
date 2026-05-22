variable "project_number" {
  description = "GCP Project Number (or ID)"
  type        = string
}

# 1. 경한님이 만든 네트워크 정보 불러오기
data "google_compute_network" "vpc" {
  name = "vpc-gcp-prd"
}

data "google_compute_subnetwork" "subnet_was_gke" {
  name   = "subnet-was-gke"
  region = "asia-northeast3"
}

# 2. GKE 클러스터 본체
resource "google_container_cluster" "primary" {
  name     = "gke-prd-cluster"
  location = "asia-northeast3-a"

  # 클러스터 삭제 보호 비활성화 (개발중/테스트 환경)
  deletion_protection = false

  # CNI cilium 사용
  datapath_provider = "ADVANCED_DATAPATH"

  # Secondary Range 연결 (VPC-native 클러스터 설정)
  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pod-range"
    services_secondary_range_name = "gke-svc-range"
  }

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = data.google_compute_network.vpc.id
  subnetwork = data.google_compute_subnetwork.subnet_was_gke.id

  workload_identity_config {
    workload_pool = "${var.project_number}.svc.id.goog"
  }

  # 프라이빗 클러스터 설정 추가
  private_cluster_config {
    enable_private_nodes    = true  # 노드들이 사설 IP만 갖도록 설정 (외부 노출 차단)
    enable_private_endpoint = false # 개발 편의를 위해 마스터 엔드포인트는 공인 유지 (필요시 주석 참고)
    
    # 구글 관리형 마스터 컨트롤 플레인용 사설 IP 대역 (/28 크기 필요)
    # 기존 VPC 내부 대역(subnet-was-gke 등) 및 대역들과 겹치지 않는 임의의 사설 IP를 지정.
    master_ipv4_cidr_block = "172.16.0.0/28" 
  }
}

# 3. Spot 인스턴스 노드 풀
resource "google_container_node_pool" "spot_nodes" {
  name       = "spot-node-pool"
  location   = "asia-northeast3-a"
  cluster    = google_container_cluster.primary.name
  node_count = 2 # 기본 2대로 시작 (필요시 변경 가능)

  node_config {
    spot         = true
    machine_type = "e2-medium"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
