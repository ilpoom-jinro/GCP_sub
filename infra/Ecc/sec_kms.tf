# kms.tf

# 1. KeyRing (열쇠고리) 생성 - 리전별로 하나씩 두는 것이 정석입니다.
resource "google_kms_key_ring" "db_keyring" {
  name     = "ilpoomjinro-db-keyring-v4"
  location = "asia-northeast3" # GCP 서울 리전
}

# 2. CryptoKey (실제 열쇠) 생성
resource "google_kms_crypto_key" "sql_disk_key" {
  name            = "sql-disk-encryption-key-v4"
  key_ring        = google_kms_key_ring.db_keyring.id
  rotation_period = "7776000s" # 90일마다 자동으로 열쇠를 교체(Rotation)하도록 설정 (보안 정석)

  lifecycle {
    prevent_destroy = false # 실수로 열쇠를 삭제하면 데이터가 영구 소실되므로 방어막을 칩니다.
  }
}

# 3. Cloud SQL 서비스 에이전트(신분증) 가져오기
# GCP가 내부적으로 Cloud SQL을 관리할 때 쓰는 특수 계정입니다.
resource "google_project_service_identity" "gcp_sa_cloudsql" {
  provider = google-beta
  project  = var.project_number
  service  = "sqladmin.googleapis.com"
}

# 4. Cloud SQL 서비스 에이전트에게 열쇠 사용 권한 부여
resource "google_kms_crypto_key_iam_member" "sql_kms_binding" {
  crypto_key_id = google_kms_crypto_key.sql_disk_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.gcp_sa_cloudsql.email}"
}