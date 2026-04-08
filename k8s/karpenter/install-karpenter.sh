#!/usr/bin/env bash
# k8s/karpenter/install-karpenter.sh
# Run from repo root after: terraform apply && aws eks update-kubeconfig
set -euo pipefail

CLUSTER_NAME="online-boutique-prod"
AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID="616919332376"
KARPENTER_VERSION="0.37.0"

# Pull values directly from terraform outputs
KARPENTER_ROLE_ARN=$(terraform -chdir=terraform/environments/prod output -raw karpenter_controller_role_arn)
INTERRUPTION_QUEUE=$(terraform -chdir=terraform/environments/prod output -raw karpenter_interruption_queue_name)

echo "1. Updating kubeconfig..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

echo "2. Registering Karpenter node role in aws-auth so launched nodes can join the cluster..."
eksctl create iamidentitymapping \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/online-boutique-prod-karpenter-node-role" \
  --username "system:node:{{EC2PrivateDNSName}}" \
  --group "system:bootstrappers,system:nodes"

echo "3. Authenticating to ECR public for Karpenter Helm chart..."
aws ecr-public get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin public.ecr.aws

echo "4. Installing Karpenter v${KARPENTER_VERSION} via Helm..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace karpenter \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${INTERRUPTION_QUEUE}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=node-type" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=system" \
  --wait

echo "5. Waiting for Karpenter to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/karpenter -n karpenter

echo "6. Applying NodePool and EC2NodeClass..."
kubectl apply -f k8s/karpenter/nodepool.yaml

echo "✅ Karpenter installed. Nodes will be provisioned automatically as pods are scheduled."
echo "   Monitor: kubectl get nodeclaims"
