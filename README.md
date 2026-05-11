# 금융권 멀티클라우드 통합 관제 플랫폼 — GCP 서브 레포

> 멀티클라우드 통합 관제 플랫폼의 **GCP DR 클러스터 및 VPN 인프라 구성** 레포입니다.  
> AWS(Active) ↔ GCP(Standby) Failover 토폴로지를 구성하며, 메인 레포는 [AWS](https://github.com/JunYoungLee260/AWS)를 참고하세요.

---

## 구성 현황

| 구성 요소 | 상태 | 설명 |
|----------|------|------|
| GCP VPC | ✅ 완료 | 서브넷, 방화벽 규칙 설정 완료 |
| Tailscale VPN Agent | ✅ 완료 | Oracle Cloud Headscale과 VPN 터널 연결 완료 |
| GKE 클러스터 | 🔄 진행 중 | 내부 클러스터 구축 및 보안 요소 추가 |
| AWS ↔ GCP Failover | 🔜 예정 | Active-Standby DR 자동화 구성 |

---

## 아키텍처

```
┌──────────────────────────────────────────┐
│        Oracle Cloud (VPN Control)        │
│         Headscale Control Plane          │
└────────────────┬─────────────────────────┘
                 │ VPN Tunnel (Tailscale)
     ┌───────────┴───────────┐
     │                       │
┌────▼──────────┐    ┌───────▼────────────┐
│     AWS       │    │        GCP         │
│  EKS (Active) │◀──▶│  GKE (Standby/DR)│
│  AI Agent     │    │  Failover 대기     │
└───────────────┘    └────────────────────┘
```

---

## 기술 스택

| 기술 | 용도 |
|------|------|
| GCP VPC / 서브넷 / 방화벽 | 네트워크 기반 구성 |
| GKE | DR용 Kubernetes 클러스터 |
| Tailscale (Agent) | Oracle Cloud Headscale과 VPN 터널링 |
| HCL (Terraform) | 인프라 코드화 |

---

## 로드맵

- [ ] GCP VPC / 서브넷 / 방화벽 구성
- [ ] Tailscale Agent 설치 및 VPN 터널 연결
- [ ] GKE 클러스터 보안 요소 추가
- [ ] AWS(Active) ↔ GCP(Standby) Failover 자동화
- [ ] On-Prem 시뮬레이션 연동 검증

---

## 관련 레포지토리

| 레포 | 설명 |
|------|------|
| [AWS](https://github.com/JunYoungLee260/AWS) | Main — AI Agent, CMP/IDP 핵심 서비스 |
| GCP_sub (현재) | GCP DR 클러스터 및 VPN 구성 |
