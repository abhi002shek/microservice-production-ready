#!/usr/bin/env bash
# k8s/argocd/install-argocd.sh
# Run from repo root after: terraform apply && aws eks update-kubeconfig
set -euo pipefail

CLUSTER_NAME="online-boutique-prod"
AWS_REGION="ap-south-1"

echo "1. Updating kubeconfig..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

echo "2. Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "3. Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "4. Applying AppProject and Application..."
kubectl apply -f k8s/argocd/project.yaml
kubectl apply -f k8s/argocd/application.yaml

echo "5. Getting initial admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "  ArgoCD admin password: ${ARGOCD_PASSWORD}"
echo "  ⚠️  Change this immediately after first login!"
echo ""
echo "6. Access ArgoCD UI via port-forward (runs in background):"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
echo "   Then open: https://localhost:8080"
echo ""
echo "   Or login via CLI:"
echo "   argocd login localhost:8080 --username admin --password '${ARGOCD_PASSWORD}' --insecure"
echo "   argocd account update-password"
echo ""
echo "✅ ArgoCD installed. ArgoCD service stays ClusterIP (not exposed publicly)."
