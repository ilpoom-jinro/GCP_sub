# vpc_sc.tf

# 1. Access Policy 생성 (조직 수준에서 하나만 존재해야 함)
# ※ 이미 정책이 있다면 해당 ID를 가져와서 사용해야 합니다.
resource "google_access_context_manager_access_policy" "main_policy" {
  parent = "organizations/${var.org_id}"
  title  = "ilpoomjinro-access-policy"
}

# 2. 보안 경계(Perimeter) 설정
resource "google_access_context_manager_service_perimeter" "bridge_perimeter" {
  parent = "accessPolicies/${google_access_context_manager_access_policy.main_policy.name}"
  name   = "accessPolicies/${google_access_context_manager_access_policy.main_policy.name}/servicePerimeters/ilpoomjinro_perimeter"
  title  = "ilpoomjinro_security_boundary"

  status {
    # 보호할 프로젝트 지정
    resources = ["projects/${var.project_number}"]

    # 보호할 서비스 목록 (Cloud SQL, Storage 등)
    restricted_services = [
      "sqladmin.googleapis.com",
      "storage.googleapis.com",
      "secretmanager.googleapis.com"
    ]

    # [중요] 경계 내부로 들어올 수 있는 통로(Access Level)
    access_levels = [google_access_context_manager_access_level.office_access.name]

    vpc_accessible_services {
      enable_restriction = true
      allowed_services   = ["RESTRICTED-SERVICES"]
    }
  }
}

# 3. 특정 조건(IP, 서비스 계정)에서만 접근을 허용하는 Access Level
resource "google_access_context_manager_access_level" "office_access" {
  parent = "accessPolicies/${google_access_context_manager_access_policy.main_policy.name}"
  name   = "accessPolicies/${google_access_context_manager_access_policy.main_policy.name}/accessLevels/allow_office_and_gke"
  title  = "allow_office_and_gke"

  basic {
    conditions {      
      # 특정 서비스 계정(GKE SA 등)만 허용
      members = [
        # 1. 애플리케이션(GKE pod)의 접근 허용
        "serviceAccount:${google_service_account.gke_sa.email}",
        # 2. 관리자(사람)의 접근 허용
        "user:your11543@gmail.com",
        "user:hsj99316@gmail.com"
      ]
    }
  }
}