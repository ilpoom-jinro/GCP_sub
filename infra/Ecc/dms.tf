# # 1. AWS PostgreSQL(소스) 연결 프로필 생성
# resource "google_database_migration_service_connection_profile" "aws_source" {
#   location              = "asia-northeast3"
#   connection_profile_id = "aws-postgres-source"
#   display_name          = "AWS PostgreSQL Source"

#   postgresql {
#     host     = "10.10.x.x" # AWS DB의 내부 IP (또는 도메인)
#     port     = 5432
#     username = "gcp_dms_user"
#     password = "임시비번"  # aws에서 생성한 복제 유저 비번
#   }
# }

# # 2. GCP PostgreSQL(타겟) 연결 프로필 생성
# resource "google_database_migration_service_connection_profile" "gcp_target" {
#   location              = "asia-northeast3"
#   connection_profile_id = "gcp-postgres-target"
#   display_name          = "GCP PostgreSQL Target"

#   postgresql {
#     host     = google_sql_database_instance.dr_standby_db.private_ip_address
#     port     = 5432
#     username = google_sql_user.db_user.name
#     password = random_password.db_password.result # security.tf의 패스워드 자동 참조
#   }
# }

# # 3. 실시간 마이그레이션(CDC) 작업(Job) 생성 및 자동 시작!
# resource "google_database_migration_service_migration_job" "cdc_job" {
#   location           = "asia-northeast3"
#   migration_job_id   = "aws-to-gcp-cdc"
#   display_name       = "AWS to GCP Realtime Sync"
#   type               = "CONTINUOUS" # 실시간 CDC 모드

#   source      = google_database_migration_service_connection_profile.aws_source.id
#   destination = google_database_migration_service_connection_profile.gcp_target.id

#   # 테라폼이 배포하자마자 마이그레이션을 자동으로 시작하게 만듭니다.
#   state = "RUNNING" 

#   # 🚨 중요: 타겟 DB 인스턴스와 유저가 완벽히 생성된 후에 DMS가 달라붙도록 순서를 강제합니다.
#   depends_on = [
#     google_sql_database_instance.dr_standby_db,
#     google_sql_user.db_user
#   ]
# }