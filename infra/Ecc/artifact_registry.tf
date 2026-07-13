# GKE DR workload images are mirrored from AWS ECR into this regional registry.
resource "google_project_service" "artifactregistry_api" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "dr_app" {
  location      = var.region
  repository_id = "dr-app"
  description   = "Mirrored stock-demo images for GKE DR"
  format        = "DOCKER"

  depends_on = [google_project_service.artifactregistry_api]
}

data "google_project" "current" {
  project_id = var.project_id
}

# The existing node pool uses the default Compute Engine service account.
resource "google_project_iam_member" "gke_node_artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}
