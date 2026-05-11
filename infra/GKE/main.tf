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
  location = "asia-northeast3-a" # 단일 AZ

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = data.google_compute_network.vpc.id
  subnetwork = data.google_compute_subnetwork.subnet_was_gke.id

  # 경한님이 설정한 Secondary Range 연결 (VPC-native 클러스터 설정)
  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pod-range"
    services_secondary_range_name = "gke-svc-range"
  }
}

# 3. Spot 인스턴스 노드 풀
resource "google_container_node_pool" "spot_nodes" {
  name       = "spot-node-pool"
  location   = "asia-northeast3-a"
  cluster    = google_container_cluster.primary.name
  node_count = 2 # 기본 2대로 시작 (필요시 변경 가능)

  node_config {
    preemptible  = true # Spot 인스턴스 활성화
    spot         = true
    machine_type = "e2-medium" 

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
