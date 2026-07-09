# governance.tf

# 1. Cloud Asset Inventory API 활성화
resource "google_project_service" "asset_inventory_api" {
  project            = var.project_number
  service            = "cloudasset.googleapis.com"
  disable_on_destroy = false
}

# 2. Security Command Center API 활성화
resource "google_project_service" "scc_api" {
  project            = var.project_number
  service            = "securitycenter.googleapis.com"
  disable_on_destroy = false
}

# 3. Cloud Audit Logs (데이터 접근 기록 활성화)
# 기본 관리자 로그 외에, '비밀번호 금고'를 누가 열어봤는지 철저하게 감시합니다.
resource "google_project_iam_audit_config" "secret_manager_audit" {
  project = var.project_number
  service = "secretmanager.googleapis.com"

  # 누군가 데이터를 읽었을 때 기록
  audit_log_config {
    log_type = "DATA_READ"
  }

  # 누군가 데이터를 쓰거나 수정했을 때 기록
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# (선택) Cloud SQL에 대한 감사 로그 활성화
# resource "google_project_iam_audit_config" "cloud_sql_audit" {
#   project = var.project_number
#   service = "sqladmin.googleapis.com"

#   audit_log_config {
#     log_type = "DATA_WRITE"
#   }
#   audit_log_config {
#     log_type = "DATA_READ"
#   }
# }