# Kubernetes Multi-App Subdomain Infrastructure

A production-ready infrastructure template for deploying multiple independent applications under separate subdomains on a single EC2 instance running k3s (lightweight Kubernetes).

**Live example:**
- `reflct.tipsytypes.com` — Angular frontend
- `reflct-api.tipsytypes.com` — Django REST API
- `pulse.tipsytypes.com` — separate backend service

Each app gets its own subdomain, TLS certificate, Helm chart, and CI/CD pipeline — all sharing one EC2 instance.

---

## Architecture

```
Internet
    │
    ▼
EC2 (t3.small) — ports 80 / 443
    │
ingress-nginx (hostNetwork DaemonSet)
    │
    ├── reflct.tipsytypes.com      → reflct-service:80
    ├── reflct-api.tipsytypes.com  → reflct-api-service:8000
    └── pulse.tipsytypes.com       → pulse-backend-service:8000

cert-manager  →  Let's Encrypt (TLS for all subdomains, shared secret)
k3s           →  containerd runtime, ECR auth via registries.yaml
Terraform     →  provisions EC2, security group, ECR repos, S3 state
```

---

## Stack

| Layer | Technology |
|---|---|
| Kubernetes | k3s (single-node, containerd) |
| Ingress | ingress-nginx (hostNetwork DaemonSet) |
| TLS | cert-manager + Let's Encrypt |
| Container registry | AWS ECR |
| Infra provisioning | Terraform (state in S3 + DynamoDB lock) |
| App packaging | Helm charts |
| CI/CD | GitHub Actions |
| Compute | AWS EC2 t3.small (Ubuntu 22.04) |

---

## Repository Structure

```
├── terraform/                  # Provisions EC2, security group, ECR repos
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── bootstrap.sh.tpl        # EC2 user-data: installs k3s, ingress-nginx, cert-manager
│
├── kube-infrasructure/         # Cluster-level manifests (applied once at bootstrap)
│   ├── ingress-prod.yaml       # Ingress rules mapping subdomains to services
│   ├── prod_issuer.yaml        # Let's Encrypt ClusterIssuer
│   └── Makefile
│
├── reflct-api/                 # Helm chart for the Django REST API
│   └── chart/
│
├── reflct/                     # Helm chart for the Angular frontend
│   └── chart/
│
└── pulse-backend/              # Helm chart for the Pulse service
    └── chart/
```

Each application lives in its own GitHub repository with its own `deploy.yml` workflow. This infra repo holds only the Helm chart skeletons and cluster-level manifests.

---

## How It Works

### Bootstrap (one-time, via Terraform)

When Terraform provisions the EC2 instance, `bootstrap.sh.tpl` runs as user-data and:

1. Installs k3s with Traefik disabled (`--disable=traefik`)
2. Writes ECR credentials to `/etc/rancher/k3s/registries.yaml` before k3s starts (containerd auth — no Docker needed)
3. Sets `write-kubeconfig-mode: "0644"` so non-root SSH sessions can run kubectl
4. Installs Helm
5. Installs ingress-nginx as a hostNetwork DaemonSet — binds EC2 ports 80/443 directly, no LoadBalancer needed
6. Installs cert-manager
7. Clones this repo and applies `prod_issuer.yaml` and `ingress-prod.yaml`
8. Sets up a cron job to refresh ECR tokens every 6 hours (tokens expire after 12h)

App secrets are **not** in this repo. Each app's CI pipeline creates its own Kubernetes secret on every deploy.

### Per-deploy CI/CD (in each app repo)

Each app's `deploy.yml` workflow:

1. Builds and pushes a Docker image to ECR (tagged `main`)
2. SSHes into EC2
3. Creates/refreshes a `kubectl secret` from GitHub repository secrets
4. Runs `helm upgrade --install` pointing at the chart in this repo
5. Forces a rollout restart so the latest image is always pulled, even when the tag stays `main`
6. Waits for the rollout to complete

---

## Adding a New App

### 1. Add a Helm chart

Copy an existing chart folder (e.g. `reflct-api/`) and update `values.yaml`:

```yaml
appName: my-app
image:
  repository: <account>.dkr.ecr.<region>.amazonaws.com/my-app
  tag: main
  pullPolicy: Always
service:
  port: 3000
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

### 2. Add the subdomain to the ingress

Edit `kube-infrasructure/ingress-prod.yaml` — add to both the `tls.hosts` list and the `rules` list:

```yaml
spec:
  tls:
    - hosts:
        - my-app.yourdomain.com     # add here
      secretName: apps-tls-prod
  rules:
    - host: my-app.yourdomain.com
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: my-app-service
                port:
                  number: 3000
```

Apply it on EC2:

```bash
ssh ubuntu@<EC2_IP>
cd infra && git pull
kubectl apply -f kube-infrasructure/ingress-prod.yaml
```

### 3. Point DNS

Create an `A` record pointing your subdomain to the EC2 public IP. cert-manager will issue the TLS certificate automatically via Let's Encrypt HTTP-01 challenge.

```
A  my-app.yourdomain.com  →  <EC2_IP>
```

### 4. Add a deploy workflow to your app repo

Use `.github/workflows/deploy.yml` from one of the existing app repos as a template. Add these GitHub secrets to your app repo:

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM credentials with ECR push access |
| `AWS_SECRET_ACCESS_KEY` | |
| `DEV_EC2_HOST` | EC2 public IP |
| `EC2_SSH_PRIVATE_KEY` | Private key matching the EC2 key pair |
| *(app secrets)* | Any env vars your app needs (DB password, API keys, etc.) |

---

## Terraform

### Prerequisites

- AWS CLI configured with appropriate permissions
- An S3 bucket and DynamoDB table for Terraform state (update the `backend` block in `terraform/main.tf`)
- An SSH key pair: `ssh-keygen -t ed25519 -f ~/.ssh/your-key`

### Provision

```bash
cd terraform
terraform init
terraform apply -var="ssh_public_key=$(cat ~/.ssh/your-key.pub)"
```

Bootstrap runs automatically and takes ~5 minutes. Watch progress:

```bash
ssh -i ~/.ssh/your-key ubuntu@<EC2_IP> "tail -f /var/log/bootstrap.log"
```

### Destroy

```bash
terraform destroy
```

---

## Secrets Management

App secrets are stored as GitHub repository secrets in each app's own repo — never in this infra repo. On every deploy the CI pipeline creates or refreshes a Kubernetes secret in the `prod` namespace:

```bash
kubectl create secret generic my-app-secrets \
  --namespace prod \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=API_KEY="$API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The Helm chart's deployment template mounts this via `secretRef`. Non-sensitive config goes in a `ConfigMap` via `configMapRef` (set in `values.yaml` under `env:`).

---

## ECR Authentication

k3s uses containerd, not Docker. ECR credentials are configured in `/etc/rancher/k3s/registries.yaml` before k3s starts — no `docker login` required. A cron job refreshes the token every 6 hours since ECR tokens expire after 12 hours. Each deploy also creates an `ecr-secret` imagePullSecret in the `prod` namespace as a belt-and-suspenders fallback.

---

## DNS Setup

All subdomains point to the same EC2 IP. ingress-nginx routes traffic by the `Host` header. TLS certificates are issued per-host by cert-manager automatically.

```
A  reflct.yourdomain.com       →  <EC2_IP>
A  reflct-api.yourdomain.com   →  <EC2_IP>
A  pulse.yourdomain.com        →  <EC2_IP>
```
