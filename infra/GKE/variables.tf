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
}

variable "gke_spot_node_min_count" {
  description = "GKE DR spot node pool minimum node count"
  type        = number
  default     = 2
}

variable "gke_spot_node_max_count" {
  description = "GKE DR spot node pool maximum node count"
  type        = number
  default     = 6
}
