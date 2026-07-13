# database.tf

# Cloud SQL Admin API 활성화
resource "google_project_service" "sqladmin_api" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

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

# DMS 서비스 대역이 VPC의 AWS 정적 경로를 사용할 수 있도록 전달합니다.
resource "google_compute_network_peering_routes_config" "service_networking" {
  network = google_compute_network.vpc_gcp_prd.name
  peering = google_service_networking_connection.private_vpc_connection.peering

  import_custom_routes = false
  export_custom_routes = true
}

# 2. Cloud SQL (PostgreSQL) 인스턴스 생성
resource "google_sql_database_instance" "dr_standby_db" {
  name             = "dr-standby-postgres"
  database_version = "POSTGRES_16"
  region           = var.region

  # DMS가 연속 복제 중 대상 인스턴스를 read replica로 전환하면 백업을 비활성화한다.
  # DR 전환 후 대상이 독립 인스턴스로 promote되면 이 예외를 제거하고 apply한다.
  lifecycle {
    ignore_changes = [settings[0].backup_configuration]
  }

  # KMS 열쇠를 사용하도록 설정 (CMEK)
  encryption_key_name = google_kms_crypto_key.sql_disk_key.id

  # 테라폼으로 destroy할 수 있도록 하는 코드
  deletion_protection = false

  # 위에서 만든 Private Connection, KMS 권한 생성에 의존 (이게 완료되어야 DB 생성 시작)
  depends_on = [google_service_networking_connection.private_vpc_connection, google_kms_crypto_key_iam_member.sql_kms_binding]

  settings {
    tier = "db-f1-micro" # [Cost Opt] 포트폴리오용이므로 가장 저렴한 최소 사양 사용

    # 구글 IAM이 아니라, PostgreSQL 엔진에게 직접 지시하는 설정(Flag)
    database_flags {
      name  = "cloudsql.logical_decoding"
      value = "on"
    }

    # AWS 장애 조치 후 Cloud SQL -> AWS RDS failback 복제를 구성할 때만 활성화합니다.
    # pglogical preload 설정 변경은 인스턴스 재시작을 유발하므로 정상 DMS 복제 중에는 false를 유지합니다.
    dynamic "database_flags" {
      for_each = var.enable_failback_publisher ? [1] : []

      content {
        name  = "cloudsql.enable_pglogical"
        value = "on"
      }
    }

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
      enabled = true
    }
  }
}
