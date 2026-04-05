#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install-argocd.sh
# Installs ArgoCD on EKS and applies the boutique project + application
# Run after: terraform apply && aws eks update-kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="online-boutique-prod"
AWS_REGION="ap-south-1"

echo "1. Updating kubeconfig..."
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

echo "2. Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "3. Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "4. Patching ArgoCD server to use LoadBalancer (internal)..."
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

echo "5. Applying ArgoCD project and application..."
kubectl apply -f k8s/argocd/project.yaml
kubectl apply -f k8s/argocd/application.yaml

echo "6. Getting initial admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD admin password: ${ARGOCD_PASSWORD}"
echo "⚠️  Change this password immediately after first login!"

echo "7. Getting ArgoCD server URL..."
kubectl get svc argocd-server -n argocd
