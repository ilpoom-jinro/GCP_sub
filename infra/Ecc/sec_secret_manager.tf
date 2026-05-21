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

# 1. Workload Identity 연동 (K8s 앱 -> GCP Secret Manager 접속용)
# GKE 내부의 'app-ksa'라는 쿠버네티스 계정이, GCP의 'gke-app-sa' 신분증을 
# 빌려 쓸 수 있도록(Impersonate) 허락해 주는 브릿지 코드.
# 이건 GKE 클러스터 생성 후에 적용해야 합니다. (왜냐면 gke-app-sa가 GKE 클러스터에서 사용될 때까지 기다려야 하니까요)

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.gke_sa.name
  role               = "roles/iam.workloadIdentityUser"
  
  # 구글이 정해둔 Workload Identity 멤버 형식 (외우지 말고 복붙하세요!)
  # 형식: serviceAccount:[프로젝트ID].svc.id.goog[[K8s네임스페이스]/[K8s서비스계정명]]
  member = "serviceAccount:${var.project_number}.svc.id.goog[default/app-ksa]"
}

# -------------------------------------------------------------------------
# 2. IAP (Identity-Aware Proxy) SSH 터널링 접속 권한 부여
# -------------------------------------------------------------------------
# 방화벽(allow-iap-ssh)은 열렸지만, 문지기가 "너 누구야?" 할 때 통과할 수 있는 
# VIP 명단(Tunnel Resource Accessor)을 등록합니다.

resource "google_project_iam_member" "iap_access_a" {
  project = var.project_number
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:your11543@gmail.com" # 내 구글 이메일
}

resource "google_project_iam_member" "iap_access_b" {
  project = var.project_number
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:hsj99316@gmail.com" # 상준님 구글 이메일
}