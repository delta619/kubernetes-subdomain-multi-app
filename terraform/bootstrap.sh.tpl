#!/bin/bash
# EC2 bootstrap: installs Docker, minikube, kubectl, helm, cert-manager
# Runs once on first boot via EC2 user data.
# Logs to /var/log/bootstrap.log

set -euo pipefail
exec > >(tee /var/log/bootstrap.log | logger -t bootstrap 2>&1) 2>&1

echo "=== Bootstrap started $(date) | env=${environment} | domain=${domain} ==="

export DEBIAN_FRONTEND=noninteractive

# ── System packages ──────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y \
  apt-transport-https ca-certificates curl gnupg lsb-release \
  conntrack socat ebtables ipset git jq unzip iptables-persistent \
  awscli

# Disable swap (k8s requirement)
swapoff -a
sed -i '/ swap /s/^/#/' /etc/fstab

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-k8s.conf
sysctl --system

# ── Docker CE ────────────────────────────────────────────────────────────────
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker
usermod -aG docker ubuntu

# ── kubectl ──────────────────────────────────────────────────────────────────
KUBECTL_VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
curl -sLO "https://dl.k8s.io/release/$${KUBECTL_VER}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# ── minikube ─────────────────────────────────────────────────────────────────
curl -sLO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64

# ── helm ─────────────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── Clone infra repo (helm charts live here) ─────────────────────────────────
git clone ${infra_repo} /home/ubuntu/infra || true
chown -R ubuntu:ubuntu /home/ubuntu/infra

# ── Start minikube (docker driver, map host 80/443 → NodePorts 30080/30443) ──
# The --ports flag tells Docker to bind host ports to the minikube container,
# so external traffic on port 80 reaches NodePort 30080 inside minikube.
sudo -u ubuntu minikube start \
  --driver=docker \
  --ports=80:30080,443:30443 \
  --cpus=no-limit \
  --memory=no-limit \
  --kubernetes-version=stable

# Enable ingress and metrics addons
sudo -u ubuntu minikube addons enable ingress
sudo -u ubuntu minikube addons enable metrics-server

# Wait for ingress controller
sudo -u ubuntu kubectl wait \
  --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

# Pin ingress-nginx NodePorts to 30080/30443 so Docker port map always matches
sudo -u ubuntu kubectl patch svc ingress-nginx-controller \
  -n ingress-nginx \
  --type='json' \
  -p='[
    {"op":"replace","path":"/spec/ports/0/nodePort","value":30080},
    {"op":"replace","path":"/spec/ports/1/nodePort","value":30443}
  ]'

# ── cert-manager ──────────────────────────────────────────────────────────────
CERT_MGR_VER="v1.14.4"
sudo -u ubuntu kubectl apply -f \
  https://github.com/cert-manager/cert-manager/releases/download/$${CERT_MGR_VER}/cert-manager.yaml

sudo -u ubuntu kubectl wait \
  --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=300s

# ── Apply k8s infrastructure (issuers + ingress) ──────────────────────────────
ISSUER_FILE="staging_issuer.yaml"
INGRESS_FILE="ingress-dev.yaml"
if [ "${environment}" = "prod" ]; then
  ISSUER_FILE="prod_issuer.yaml"
  INGRESS_FILE="echo_ingress.yaml"
fi

sudo -u ubuntu kubectl apply -f /home/ubuntu/infra/kube-infrasructure/$${ISSUER_FILE}
sudo -u ubuntu kubectl apply -f /home/ubuntu/infra/kube-infrasructure/$${INGRESS_FILE}

# ── ECR login helper (refreshes every 12 hours) ───────────────────────────────
cat > /usr/local/bin/ecr-login.sh << 'ECRSCRIPT'
#!/bin/bash
AWS_REGION="${aws_region}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
    $${ACCOUNT_ID}.dkr.ecr.$${AWS_REGION}.amazonaws.com
ECRSCRIPT
chmod +x /usr/local/bin/ecr-login.sh

# Run ECR login now and schedule refresh
/usr/local/bin/ecr-login.sh || echo "ECR login skipped (no ECR yet)"
echo "0 */12 * * * ubuntu /usr/local/bin/ecr-login.sh" >> /etc/crontab

# ── Systemd: restart minikube + re-apply port patch on reboot ─────────────────
cat > /etc/systemd/system/minikube.service << 'UNIT'
[Unit]
Description=Minikube Kubernetes
After=docker.service
Requires=docker.service

[Service]
Type=forking
User=ubuntu
Group=ubuntu
ExecStart=/usr/local/bin/minikube start --driver=docker --ports=80:30080,443:30443
ExecStartPost=/bin/bash -c '\
  sleep 30 && \
  sudo -u ubuntu kubectl patch svc ingress-nginx-controller -n ingress-nginx \
    --type=json \
    -p=[{"op":"replace","path":"/spec/ports/0/nodePort","value":30080},{"op":"replace","path":"/spec/ports/1/nodePort","value":30443}] \
  || true'
ExecStop=/usr/local/bin/minikube stop
RemainAfterExit=yes
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable minikube

echo "=== Bootstrap complete $(date) ==="
echo "EC2 is ready. Access the cluster:"
echo "  ssh ubuntu@<EC2-IP>"
echo "  kubectl get pods -A"
