#!/usr/bin/env bash
# install-controllers.sh
# Installs AWS Load Balancer Controller only
# Karpenter is installed separately via k8s/karpenter/install-karpenter.sh
set -euo pipefail

CLUSTER_NAME="online-boutique-prod"
AWS_REGION="ap-south-1"
AWS_ACCOUNT_ID="616919332376"

echo "1. Updating kubeconfig..."
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

echo "2. Adding EKS Helm repo..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo "3. Creating IAM policy for AWS Load Balancer Controller..."
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json 2>/dev/null || echo "Policy already exists, skipping."

rm -f iam_policy.json

echo "4. Creating service account with IRSA (no static keys in cluster)..."
eksctl create iamserviceaccount \
  --cluster=${CLUSTER_NAME} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region ${AWS_REGION}

echo "5. Installing AWS Load Balancer Controller..."
VPC_ID=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text \
  --region ${AWS_REGION})

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${AWS_REGION} \
  --set vpcId=${VPC_ID} \
  --wait

echo "✅ AWS Load Balancer Controller installed"
kubectl get pods -n kube-system | grep aws-load-balancer
