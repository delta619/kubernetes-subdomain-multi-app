#!/bin/bash
# Run this on the EC2 instance AFTER Terraform bootstrap completes,
# if you need to manually (re-)apply k8s resources.
# Bootstrap.sh already runs this automatically on first boot.

set -euo pipefail

ENVIRONMENT=${1:-dev}
INFRA_DIR="/home/ubuntu/infra"

echo "Setting up k8s resources for environment: $ENVIRONMENT"

cd "$INFRA_DIR"
git pull origin main

if [ "$ENVIRONMENT" = "prod" ]; then
  ISSUER="kube-infrasructure/prod_issuer.yaml"
  INGRESS="kube-infrasructure/echo_ingress.yaml"
else
  ISSUER="kube-infrasructure/staging_issuer.yaml"
  INGRESS="kube-infrasructure/ingress-dev.yaml"
fi

kubectl apply -f "$ISSUER"
kubectl apply -f "$INGRESS"

echo "Done. Ingress rules:"
kubectl get ingress
echo ""
echo "Cert-manager certificates:"
kubectl get certificate 2>/dev/null || true
