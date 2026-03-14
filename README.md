# n8n on Kubernetes (queue mode with Redis/Valkey)

Kubernetes manifests to run **n8n** in **queue mode**: one main instance (UI + API + enqueue) and multiple workers that consume workflow executions from a **Redis/Valkey** queue. Uses **Kustomize** (base + dev/prod overlays), **Argo CD** for GitOps, and optional **KEDA** / **Cluster Autoscaler**.

---

## Why this?

- **Queue mode**: Workflow runs are offloaded to workers via Redis (Bull), so the main instance stays responsive and you can scale workers independently.
- **Redis/Valkey**: Single shared queue and cache; main and workers use the same Redis (e.g. AWS ElastiCache for Valkey).
- **Kustomize**: One base, overlays for `n8n-dev` and `n8n-prod` (namespace, image, replicas).
- **Argo CD**: GitOps—push to Git, Argo CD syncs and deploys to dev/prod.
- **Kubernetes**: Rolling updates, health checks, PDB, and (with KEDA + Cluster Autoscaler) automatic scaling of both pods and nodes.

---

## Repo layout

| Path | Purpose |
|------|--------|
| **base/** | Shared manifests: n8n-main (StatefulSet), n8n-worker (Deployment), service, ingress, pdb, hpa. |
| **overlays/dev/** | Namespace `n8n-dev`, image override, replicas (e.g. main=2). |
| **overlays/prod/** | Namespace `n8n-prod`, image override, replicas (e.g. worker=3). |
| **overlays/*/n8n-env.env.example** | Template for env vars (DB, Redis, N8N_*). Copy to `n8n-env.env` (gitignored) for local `kubectl apply -k`. |
| **argocd/** | Argo CD operator/instance and Application manifests (if used). |
| **Jenkinsfile** | Build app image, push to ECR, update overlay `newTag` to `fcc_<BUILD_NUMBER>`, commit and push. |

**Required secret (per namespace):** `n8n-env` with DB_*, N8N_ENCRYPTION_KEY, QUEUE_BULL_REDIS_*. Not stored in Git; create once per namespace (see below).

---

## Kustomize

- **Base:** `base/kustomization.yaml` lists all shared resources (n8n-main, n8n-worker, service, ingress, pdb, hpa).
- **Overlays:** `overlays/dev` and `overlays/prod` set `namespace`, `images` (ECR + tag), and `replicas`. No `secretGenerator` in Git so Argo CD can build without the env file.

**Local apply (when you have `n8n-env.env`):**

```bash
# Create secret once per namespace (see "Secret: one-time per namespace" below)
kubectl create secret generic n8n-env -n n8n-dev --from-env-file=overlays/dev/n8n-env.env
kubectl create secret generic n8n-env -n n8n-prod --from-env-file=overlays/prod/n8n-env.env

kubectl apply -k overlays/dev
kubectl apply -k overlays/prod
```

---

## Argo CD installation and setup

### 1. Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
```

### 2. Get admin password and login

```bash
# Initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d

# Login (use your LoadBalancer host and the password from above)
argocd login <ARGOCD_SERVER_HOST> --username admin --password <PASSWORD> --insecure
# Example:
# argocd login a39fc89f4f6284163bec4ce8a4292d41-1519723699.us-east-1.elb.amazonaws.com \
#   --username admin --password <PASSWORD> --insecure
```

Check version: `argocd version`

### 3. Add Git repo (SSH)

```bash
argocd repo add git@github.com:SanthaprakashMahendran/N8n_App.git --ssh-private-key-path ~/.ssh/id_rsa
```

### 4. Create secret first (one-time per namespace)

**The `n8n-env` secret must exist in each target namespace before (or right after) the first Argo CD sync.** It is not in Git, so create it once per environment:

```bash
# Dev
kubectl create secret generic n8n-env -n n8n-dev --from-env-file=overlays/dev/n8n-env.env
# Prod
kubectl create secret generic n8n-env -n n8n-prod --from-env-file=overlays/prod/n8n-env.env
```

Use `overlays/*/n8n-env.env.example` as a template; copy to `n8n-env.env`, fill in values, then run the above. **You only need to create this secret once per namespace** unless you rotate DB/Redis credentials or add new keys.

### 5. Create Applications in Argo CD

Create Applications (UI or CLI) that point at this repo:

- **n8n-dev:** source repo `SanthaprakashMahendran/N8n_App.git`, path `overlays/dev`, destination namespace `n8n-dev`.
- **n8n-prod:** source repo same, path `overlays/prod`, destination namespace `n8n-prod`.

After sync, Argo CD will deploy n8n to `n8n-dev` and `n8n-prod`. List apps: `kubectl get applications -n argocd`.

---

## Secret: one-time per namespace

**Yes. The `n8n-env` secret needs to be created only once per namespace** (e.g. once in `n8n-dev`, once in `n8n-prod`). Argo CD does not manage it (it is not in Git). After creation, it stays until you delete it or replace it. Re-run the `kubectl create secret generic n8n-env ...` only if you change DB/Redis credentials or need to add/update env vars.

---

## Quick apply (without Argo CD)

```bash
kubectl create namespace n8n
# Create n8n-env secret (see above)
kubectl apply -f base/service.yaml -f base/n8n-main.yaml -f base/n8n-worker.yaml -n n8n
kubectl apply -f base/ingress.yaml -f base/pdb.yaml -n n8n
```

Or use overlays: `kubectl apply -k overlays/dev` (after creating the secret in that namespace). Use either KEDA or HPA for worker scaling, not both.

---

## What's in base/

| File | Purpose |
|------|--------|
| **n8n-main.yaml** | StatefulSet: web UI + API, enqueues jobs to Redis, 10Gi PVC (gp3). |
| **n8n-worker.yaml** | Deployment: runs `n8n worker`, consumes from Redis Bull queue. |
| **service.yaml** | Headless Service for n8n-main. |
| **ingress.yaml** | ALB Ingress (AWS) to n8n-main:80. |
| **pdb.yaml** | PodDisruptionBudget: min 1 available across main + workers. |
| **hpa.yaml** | CPU-based HPA for workers (alternative to KEDA; do not use both). |

Optional (see below): **keda-scaledobject-worker.yaml**, **cluster-autoscaler-autodiscover.yaml**, **storageclass-gp3.yaml**.

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
