# GKE DR Gateway가 재배포되어도 Route 53 대상 주소가 바뀌지 않도록 고정 외부 IP를 예약한다.
resource "google_compute_address" "gke_dr_gateway" {
  name         = "gke-dr-gateway-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  description = "Static external IP for the GKE DR Istio Gateway"
}

output "gke_dr_gateway_ip" {
  description = "Route 53 GCP_SERVICE_IP value for the GKE DR Gateway"
  value       = google_compute_address.gke_dr_gateway.address
}
