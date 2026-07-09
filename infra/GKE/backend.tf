terraform {
  backend "gcs" {
    bucket = "ilpoomjinro-tfstate-0430"
    prefix = "terraform/state/gke"
  }
}
