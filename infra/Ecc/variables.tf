# variables.tf
variable "org_id" {
  description = "GCP Organization ID"
  type        = string
}

variable "project_number" {
  description = "GCP Project Number"
  type        = string
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "ilpoomjinro"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "asia-northeast3"
}

variable "tailscale_auth_key" {
  description = "Headscale preauth key used to register the GCP subnet router"
  type        = string
  sensitive   = true
}

variable "enable_dms" {
  description = "AWS PostgreSQL -> Cloud SQL DMS resources creation toggle"
  type        = bool
  default     = false
}

variable "dms_source_host" {
  description = "AWS RDS source host reachable from GCP DMS through the private connectivity path"
  type        = string
  default     = ""
}

variable "dms_source_port" {
  description = "AWS RDS source PostgreSQL port"
  type        = number
  default     = 5432
}

variable "dms_source_database" {
  description = "AWS RDS source database name"
  type        = string
  default     = "financial_service"
}

variable "dms_source_username" {
  description = "AWS RDS source replication user for DMS"
  type        = string
  default     = "gcp_dms_user"
}

variable "dms_source_password" {
  description = "AWS RDS source replication user password for DMS"
  type        = string
  sensitive   = true
  default     = ""
}

variable "dms_desired_state" {
  description = "DMS migration job desired state. Keep NOT_STARTED until source connectivity is verified."
  type        = string
  default     = "NOT_STARTED"
}
