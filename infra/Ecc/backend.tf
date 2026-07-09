# backend.tf
terraform {
  # 1. 상태 파일 저장소 설정 (GCS)
  backend "gcs" {
    bucket = "ilpoomjinro-tfstate-0430"

    # ★ 매우 중요: 상태 파일이 버킷 내부에 저장될 경로입니다.
    # 인프라 레이어별로 분리하기 위해 'base'라는 경로를 지정합니다.
    prefix = "terraform/state/base"
  }

  # 2. 필요한 프로바이더 설정
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}

# 3. 구글 클라우드 프로바이더 설정
provider "google" {
  project = var.project_id
  region  = var.region # 서울 리전
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
