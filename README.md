# n8n on Kubernetes (queue mode with Redis/Valkey)

Kubernetes manifests to run **n8n** in **queue mode**: one main instance (UI + API + enqueue) and multiple workers that consume workflow executions from a **Redis/Valkey** queue. Optional **KEDA** scales workers by queue depth; optional **Cluster Autoscaler** scales nodes.

---

## Why this?

- **Queue mode**: Workflow runs are offloaded to workers via Redis (Bull), so the main instance stays responsive and you can scale workers independently.
- **Redis/Valkey**: Single shared queue and cache; main and workers use the same Redis (e.g. AWS ElastiCache for Valkey).
- **Kubernetes**: Rolling updates, health checks, PDB, and (with KEDA + Cluster Autoscaler) automatic scaling of both pods and nodes.

---

## What's in this repo

| File | Purpose |
|------|--------|
| **n8n-main.yaml** | StatefulSet: 1 replica, web UI + API, enqueues jobs to Redis, 10Gi PVC (gp3). |
| **n8n-worker.yaml** | Deployment: runs `n8n worker`, consumes from Redis Bull queue, 2 replicas min. |
| **service.yaml** | Headless Service for n8n-main (StatefulSet). |
| **ingress.yaml** | ALB Ingress (AWS) to n8n-main:80. |
| **pdb.yaml** | PodDisruptionBudget: min 1 available across main + workers. |
| **storageclass-gp3.yaml** | StorageClass for main PVC (EBS gp3). |
| **keda-scaledobject-worker.yaml** | KEDA ScaledObject: scale workers by Redis list `bull:jobs:wait` (use OR HPA, not both). |
| **hpa.yaml** | CPU-based HPA for workers (alternative to KEDA; do not use both). |
| **cluster-autoscaler-autodiscover.yaml** | Cluster Autoscaler (EKS): scale node groups by pending/underutilized pods. |

**Required secret:** `n8n-env` in namespace `n8n` with DB_*, N8N_ENCRYPTION_KEY, QUEUE_BULL_REDIS_HOST, QUEUE_BULL_REDIS_PORT (and QUEUE_BULL_REDIS_PASSWORD if Redis uses auth).

 kubectl create secret generic n8n-env \
  -n n8n \
  --from-literal=DB_TYPE=postgresdb \
  --from-literal=DB_POSTGRESDB_HOST=n8n-postgres.c4n0m4skmzkn.us-east-1.rds.amazonaws.com \
  --from-literal=DB_POSTGRESDB_PORT=5432 \
  --from-literal=DB_POSTGRESDB_DATABASE=n8n \
  --from-literal=DB_POSTGRESDB_USER=root \
  --from-literal=DB_POSTGRESDB_PASSWORD=SuperStrongPassword123! \
  --from-literal=DB_POSTGRESDB_SSL=true \
  --from-literal=DB_POSTGRESDB_SSL_MODE=require \
  --from-literal=DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false \
  --from-literal=N8N_ENCRYPTION_KEY=super-secret-encryption-key \
  --from-literal=N8N_HOST=0.0.0.0 \
  --from-literal=N8N_PORT=5678 \
  --from-literal=N8N_PROTOCOL=http \
  --from-literal=N8N_SECURE_COOKIE=false \
  --from-literal=EXECUTIONS_MODE=queue \
  --from-literal=QUEUE_BULL_REDIS_HOST=master.redis-que.nr1pf5.use1.cache.amazonaws.com \
  --from-literal=QUEUE_BULL_REDIS_PORT=6379 \
  --from-literal=QUEUE_BULL_REDIS_TLS=true \
  --from-literal=QUEUE_BULL_REDIS_TLS_REJECT_UNAUTHORIZED=false

---

## Quick apply (core)

```bash
kubectl create namespace n8n
# Create n8n-env secret with DB + Redis + N8N_ENCRYPTION_KEY
kubectl apply -f storageclass-gp3.yaml
kubectl apply -f service.yaml -f n8n-main.yaml -f n8n-worker.yaml -n n8n
kubectl apply -f ingress.yaml -f pdb.yaml -n n8n
```

Use either KEDA or HPA for worker scaling, not both.

---

## How it was created for Redis (brief)

1. **Provision Redis** (e.g. ElastiCache for Valkey): same VPC as EKS, host:port, TLS/auth if needed.
2. **Namespace + secret:** create `n8n-env` with DB, N8N_ENCRYPTION_KEY, QUEUE_BULL_REDIS_HOST, QUEUE_BULL_REDIS_PORT.
3. **Deploy:** storageclass, service, n8n-main.yaml, n8n-worker.yaml (main=queue mode, workers=args: ["worker"]).
4. **Expose:** ingress.yaml, pdb.yaml.
5. **Scaling:** KEDA (keda-scaledobject-worker.yaml) or HPA (hpa.yaml)—not both.
6. **Optional:** Cluster Autoscaler: IAM role, ASG tags, set cluster name in YAML, apply.

---

# Deep setup: Redis, Cluster Autoscaler, KEDA

---

## Part 1: Creating Redis (Valkey) – AWS ElastiCache

- **Why:** n8n queue mode uses Redis for Bull queue (`bull:jobs:wait`) and cache (`n8n:cache:*`).
- **Steps:** ElastiCache → Create → Redis 7 or Valkey; same VPC as EKS; security group TCP 6379 from EKS nodes; optional TLS and auth token. Note Primary endpoint; put QUEUE_BULL_REDIS_HOST, QUEUE_BULL_REDIS_PORT (and QUEUE_BULL_REDIS_PASSWORD if set) in secret `n8n-env`.
- **Verify:** `kubectl run redis-test --image=redis:7 -n n8n --restart=Never --rm -it -- redis-cli -h <HOST> -p 6379 --tls --insecure PING`

---

## Part 2: Cluster Autoscaler

- **What:** Scales **nodes** up when pods are Pending (e.g. Insufficient memory), down when nodes underutilized.
- **Steps:**
  1. IAM role (e.g. ClusterAutoscalerRole) with trust for `system:serviceaccount:kube-system:cluster-autoscaler` and policy: autoscaling:Describe*, SetDesiredCapacity; ec2:DescribeLaunchTemplateVersions, DescribeInstanceTypes, etc.
  2. Tag each node ASG: `k8s.io/cluster-autoscaler/enabled=true`, `k8s.io/cluster-autoscaler/<CLUSTER_NAME>=owned`.
  3. Edit cluster-autoscaler-autodiscover.yaml: role ARN in ServiceAccount; replace `ci-eks-cluster` in --node-group-auto-discovery with your EKS cluster name.
  4. `kubectl apply -f cluster-autoscaler-autodiscover.yaml`
- **Verify:** `kubectl get pods -n kube-system -l app=cluster-autoscaler` and logs.

---

## Part 3: KEDA

- **What:** Scales **n8n-worker** pods by Redis list `bull:jobs:wait` length.
- **Steps:**
  1. Install: `helm repo add kedacore https://kedacore.github.io/charts && helm install keda kedacore/keda -n keda --create-namespace`
  2. Edit keda-scaledobject-worker.yaml: set Redis address (host:port); enableTLS/unsafeSsl for ElastiCache TLS; add authenticationRef if Redis has password.
  3. `kubectl apply -f keda-scaledobject-worker.yaml -n n8n`
  4. `kubectl delete hpa n8n-hpa -n n8n` (do not use both KEDA and HPA for n8n-worker)
- **Verify:** `kubectl get scaledobject,hpa -n n8n` and `kubectl logs -n keda -l app=keda-operator --tail=50`

---

## Summary

| Component | Purpose |
|----------|---------|
| **Redis (Valkey)** | Queue + cache; main enqueues, workers consume. |
| **Cluster Autoscaler** | Scale nodes when pending or underutilized. |
| **KEDA** | Scale n8n-worker pods by bull:jobs:wait length. |
