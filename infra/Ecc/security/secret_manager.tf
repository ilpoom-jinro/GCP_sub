# secret_manager.tf

# 1. 강력한 랜덤 패스워드 생성
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# 2. Secret Manager에 비밀번호 저장소 만들기
resource "google_secret_manager_secret" "db_secret" {
  secret_id = "ilpoomjinro-db-password"
  
  replication {
    auto {} # 구글이 알아서 가장 안전한 리전에 분산 복제하도록 맡깁니다.
  }
}

# 3. 생성된 패스워드를 Secret Manager 저장소에 쏙 넣기
resource "google_secret_manager_secret_version" "db_secret_version" {
  secret      = google_secret_manager_secret.db_secret.id
  secret_data = random_password.db_password.result
}

# 4. GKE Pod(애플리케이션)가 구글 서비스를 호출할 때 사용할 '신분증(Service Account)' 생성
resource "google_service_account" "gke_sa" {
  account_id   = "gke-app-sa"
  display_name = "GKE Application Service Account"
}

# 5. GKE 신분증에 Secret Manager 금고를 '읽을 수 있는 권한(Accessor)' 부여
resource "google_secret_manager_secret_iam_member" "gke_sa_secret_access" {
  secret_id = google_secret_manager_secret.db_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.gke_sa.email}"
}