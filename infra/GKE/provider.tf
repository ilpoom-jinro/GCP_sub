terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.31"
    }
  }
}

provider "google" {
  project = "ilpoomjinro"
  region  = "asia-northeast3"
}
