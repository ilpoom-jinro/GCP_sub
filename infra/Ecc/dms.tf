resource "google_project_service" "database_migration_api" {
  service            = "datamigration.googleapis.com"
  disable_on_destroy = false
}

resource "google_database_migration_service_connection_profile" "aws_source" {
  count = var.enable_dms ? 1 : 0

  location              = var.region
  connection_profile_id = "aws-postgres-source"
  display_name          = "AWS financial-service PostgreSQL source"

  postgresql {
    host     = var.dms_source_host
    port     = var.dms_source_port
    username = var.dms_source_username
    password = var.dms_source_password
  }

  depends_on = [
    google_project_service.database_migration_api
  ]
}

# 기존 Cloud SQL 인스턴스는 DMS가 migration 중 replica로 전환합니다.
# 따라서 목적지 connection profile과 migration job은 네트워크 검증 후 gcloud로
# 생성하며, Terraform이 migration 중인 인스턴스를 다시 조정하지 않도록 분리합니다.
