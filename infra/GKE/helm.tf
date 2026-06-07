# 1. Gateway API CRD 설치 (Istio Ambient Mesh의 필수 전제 조건)
resource "null_resource" "gateway_api_crd" {
  provisioner "local-exec" {
    command = "kubectl get crd gateways.gateway.networking.k8s.io || kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml"
  }
  depends_on = [google_container_cluster.primary]
}

# 2. Istio Base 설치
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  namespace        = "istio-system"
  create_namespace = true
  depends_on       = [null_resource.gateway_api_crd]
}

# 3. Istiod (Control Plane) 설치 - Ambient 프로필 적용
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  namespace  = "istio-system"
  
  set {
    name  = "profile"
    value = "ambient"
  }
  depends_on = [helm_release.istio_base]
}

# 4. Istio CNI 설치 (중요: GKE 환경 맞춤형 경로 설정)
resource "helm_release" "istio_cni" {
  name       = "istio-cni"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "cni"
  namespace  = "istio-system"
  
  set {
    name  = "profile"
    value = "ambient"
  }
  set {
    name  = "cni.cniBinDir"
    value = "/home/kubernetes/bin"
  }
  #  GKE 보안 정책 충돌을 피하기 위해 VIP 패스 제거
  set {
    name  = "priorityClassName"
    value = ""
  }
  depends_on = [helm_release.istiod]
}

# 5. Ztunnel 설치 (노드마다 생성되는 초경량 보안 프록시 터널)
resource "helm_release" "ztunnel" {
  name       = "ztunnel"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "ztunnel"
  namespace  = "istio-system"
  depends_on = [helm_release.istio_cni]
}

# 6. ArgoCD 자동 설치 및 외부 접속 로드밸런서 설정
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  depends_on       = [google_container_cluster.primary]

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
}