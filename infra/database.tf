# database.tf

# 1. Private Services Access (Cloud SQL을 Private IP로만 띄우기 위한 사전 작업)
# 이 작업이 없으면 Cloud SQL이 내부 IP를 할당받지 못합니다.
resource "google_compute_global_address" "private_ip_address" {
  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.vpc_gcp_prd.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc_gcp_prd.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# 2. Cloud SQL (MySQL) 인스턴스 생성
resource "google_sql_database_instance" "dr_standby_db" {
  name             = "dr-standby-mysql"
  database_version = "MYSQL_8_0"
  region           = "asia-northeast3"

  # 이 줄을 명시적으로 추가해야 테라폼이 삭제를 승인합니다.
  deletion_protection = false

  # 위에서 만든 Private Connection에 의존 (이게 완료되어야 DB 생성 시작)
  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = "db-f1-micro" # [Cost Opt] 포트폴리오용이므로 가장 저렴한 최소 사양 사용
    
    # 디스크 자동 확장 켜기
    disk_autoresize = true

    ip_configuration {
      ipv4_enabled    = false # [Security] 공인 IP 절대 부여 금지!
      private_network = google_compute_network.vpc_gcp_prd.id
      
      # 방화벽 없이 Cloud SQL에 붙을 수 있도록 IAP 설정 가능성 열어두기
      enable_private_path_for_google_cloud_services = true
    }

    # aws에서 복제(Replication)를 받아오기 위한 필수 세팅
    # (실제 복제 설정은 나중에 gcloud 명령어나 콘솔에서 세부적으로 잡아줘야 합니다.)
    backup_configuration {
      enabled            = true
      binary_log_enabled = true # 백업과 바이너리 로그가 켜져 있어야 복제가 가능합니다.
    }
  }
}

# 3. 데이터베이스 생성
resource "google_sql_database" "main_db" {
  name     = "ilpoomjinro_db"
  instance = google_sql_database_instance.dr_standby_db.name
}

# 4. DB 유저 생성
resource "google_sql_user" "db_user" {
  name     = "admin"
  instance = google_sql_database_instance.dr_standby_db.name
  password = "SuperSecretPassword123!" # 실무에선 Secret Manager 연동 필수!
}