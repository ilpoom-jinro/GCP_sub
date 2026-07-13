# GKE DR 자동 확장

GKE DR 서비스는 두 단계로 확장한다.

1. HorizontalPodAutoscaler(HPA)가 평균 CPU 사용률이 70%를 넘으면 `stock-api`는 2개에서 최대 30개, `stock-web`은 2개에서 최대 20개 Pod까지 확장한다.
2. Pod 요청량을 수용할 노드가 부족하면 GKE Cluster Autoscaler가 `spot-node-pool`을 2개에서 최대 6개까지 확장한다.

Pod 축소에는 5분 안정화 구간을 두어, 짧은 트래픽 변동으로 Pod가 즉시 줄었다 다시 늘어나는 현상을 줄인다. 노드 축소는 GKE가 안전하게 재배치 가능한 Pod가 있을 때 수행한다.

## 적용

1. `infra/GKE`의 Terraform apply를 실행한다. node pool autoscaling 설정은 기존 노드 풀을 교체하지 않고 갱신된다.
2. `Deploy GKE DR Service` workflow를 다시 실행하거나 아래를 실행해 HPA 매니페스트를 적용한다.

```bash
kubectl apply -k k8s/stock-demo
```

## 확인

```bash
kubectl -n stock-demo get hpa -w
kubectl get nodes -l cloud.google.com/gke-nodepool=spot-node-pool -w
kubectl top pods -n stock-demo
```

`kubectl top` 명령이 값을 출력하지 않으면 Metrics Server가 준비될 때까지 잠시 기다린다. GKE에서는 Metrics Server가 기본 제공된다.

## 부하 테스트

GKE 클러스터에 도달 가능한 환경에서 Gateway 외부 IP로 테스트한다. 실제 운영 도메인과 Route 53 failover 설정 전에는 GCP Gateway 주소를 직접 사용한다.

```bash
kubectl -n stock-demo get gateway stock-gw
```

테스트를 마친 후 부하 도구를 중지하면 HPA는 안정화 시간 이후 최소 2개 Pod로 돌아가고, 유휴 노드는 Cluster Autoscaler가 축소한다.

## 운영 주의사항

- Spot 노드는 중단될 수 있으므로 최소 노드 수 2개만으로는 가용성을 완전히 보장하지 않는다.
- 최대 노드 수 6개, backend Pod 최대 30개, frontend Pod 최대 20개는 초기 DR 한도다. 실제 부하 시험 결과와 Cloud SQL 연결 한도를 기준으로 조정한다.
- HPA는 CPU 요청량을 기준으로 계산하므로 Deployment의 `resources.requests.cpu`를 제거하면 안 된다.
