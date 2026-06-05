terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.31"
    }
    # 쿠버네티스 패키지 매니저(Helm) 자동화 도구 추가
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "google" {
  project = "ilpoomjinro"       
  region  = "asia-northeast3"   
}

# 생성된 GKE 클러스터의 인증 정보를 가져와서 Helm에 전달
data "google_client_config" "default" {}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth.0.cluster_ca_certificate)
  }
}