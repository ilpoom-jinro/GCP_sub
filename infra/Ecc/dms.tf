resource "google_project_service" "database_migration_api" {
  service            = "datamigration.googleapis.com"
  disable_on_destroy = false
}

resource "google_database_migration_service_connection_profile" "aws_source" {
  count = var.enable_dms ? 1 : 0

  location              = var.region
  connection_profile_id = "aws-postgres-source"
  display_name          = "AWS financial-service PostgreSQL source"

  postgresql {
    host     = var.dms_source_host
    port     = var.dms_source_port
    username = var.dms_source_username
    password = var.dms_source_password
  }

  depends_on = [
    google_project_service.database_migration_api
  ]
}

resource "google_database_migration_service_connection_profile" "gcp_target" {
  count = var.enable_dms ? 1 : 0

  location              = var.region
  connection_profile_id = "gcp-postgres-target"
  display_name          = "GCP Cloud SQL PostgreSQL target"

  postgresql {
    host     = google_sql_database_instance.dr_standby_db.private_ip_address
    port     = 5432
    username = google_sql_user.db_user.name
    password = random_password.db_password.result
  }

  depends_on = [
    google_sql_database_instance.dr_standby_db,
    google_sql_database.financial_service_db,
    google_sql_user.db_user,
    google_project_service.database_migration_api
  ]
}

resource "google_database_migration_service_migration_job" "aws_to_gcp_cdc" {
  provider = google-beta
  count    = var.enable_dms ? 1 : 0

  location         = var.region
  migration_job_id = "aws-to-gcp-cdc"
  display_name     = "AWS financial-service to GCP Cloud SQL CDC"
  type             = "CONTINUOUS"
  desired_state    = var.dms_desired_state

  source      = google_database_migration_service_connection_profile.aws_source[0].name
  destination = google_database_migration_service_connection_profile.gcp_target[0].name

  vpc_peering_connectivity {
    vpc = google_compute_network.vpc_gcp_prd.id
  }

  depends_on = [
    google_database_migration_service_connection_profile.aws_source,
    google_database_migration_service_connection_profile.gcp_target
  ]
}
