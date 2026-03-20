#!/bin/bash
# EC2 bootstrap: installs k3s, ingress-nginx, cert-manager
# Runs once on first boot via EC2 user data.
# Logs to /var/log/bootstrap.log

set -euo pipefail
exec > >(tee /var/log/bootstrap.log | logger -t bootstrap 2>&1) 2>&1

echo "=== Bootstrap started $(date) | env=${environment} | domain=${domain} ==="

export DEBIAN_FRONTEND=noninteractive

# ── System packages ───────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y \
  apt-transport-https ca-certificates curl gnupg lsb-release \
  git jq unzip awscli

# Disable swap (k8s requirement)
swapoff -a
sed -i '/ swap /s/^/#/' /etc/fstab

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-k8s.conf
sysctl --system

# ── ECR registry config (written before k3s starts so no restart needed) ─────
AWS_REGION="${aws_region}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_TOKEN=$(aws ecr get-login-password --region "$${AWS_REGION}")
ECR_REGISTRY="$${ACCOUNT_ID}.dkr.ecr.$${AWS_REGION}.amazonaws.com"

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml << EOF
configs:
  "$${ECR_REGISTRY}":
    auth:
      username: AWS
      password: "$${ECR_TOKEN}"
EOF

# ── k3s (disable Traefik — using ingress-nginx instead) ───────────────────────
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable=traefik" sh -

# Wait for node to be ready
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  echo "Waiting for k3s node..."
  sleep 5
done

# Configure kubectl for ubuntu user
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
chmod 600 /home/ubuntu/.kube/config
echo 'export KUBECONFIG=/home/ubuntu/.kube/config' >> /home/ubuntu/.bashrc
echo 'export KUBECONFIG=/home/ubuntu/.kube/config' >> /home/ubuntu/.profile

# Allow non-root kubectl access (needed for SSH sessions that don't source .bashrc)
chmod 644 /etc/rancher/k3s/k3s.yaml

# Root uses k3s kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── helm ──────────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── ECR token refresh (tokens expire every 12 h) ──────────────────────────────
cat > /usr/local/bin/refresh-ecr.sh << 'ECRSCRIPT'
#!/bin/bash
set -e
AWS_REGION="${aws_region}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$${ACCOUNT_ID}.dkr.ecr.$${AWS_REGION}.amazonaws.com"
ECR_TOKEN=$(aws ecr get-login-password --region "$${AWS_REGION}")
cat > /etc/rancher/k3s/registries.yaml << EOF
configs:
  "$${ECR_REGISTRY}":
    auth:
      username: AWS
      password: "$${ECR_TOKEN}"
EOF
systemctl restart k3s
sleep 30  # wait for k3s to come back
ECRSCRIPT
chmod +x /usr/local/bin/refresh-ecr.sh
echo "0 */6 * * * root /usr/local/bin/refresh-ecr.sh" >> /etc/crontab

# ── ingress-nginx (hostNetwork → binds directly to EC2 ports 80 / 443) ────────
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.kind=DaemonSet \
  --set controller.service.type=ClusterIP

kubectl wait \
  --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

# ── cert-manager ──────────────────────────────────────────────────────────────
CERT_MGR_VER="v1.14.4"
kubectl apply -f \
  https://github.com/cert-manager/cert-manager/releases/download/$${CERT_MGR_VER}/cert-manager.yaml

kubectl wait \
  --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=300s

# ── Clone infra repo (helm charts + k8s manifests live here) ──────────────────
git clone ${infra_repo} /home/ubuntu/infra || true
chown -R ubuntu:ubuntu /home/ubuntu/infra

# ── Apply k8s infrastructure (issuers + ingress) ──────────────────────────────
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f /home/ubuntu/infra/kube-infrasructure/prod_issuer.yaml || true
kubectl apply -f /home/ubuntu/infra/kube-infrasructure/ingress-prod.yaml || true

echo "=== Bootstrap complete $(date) ==="
echo "k3s is ready. SSH in and run: sudo kubectl get pods -A"
