#!/usr/bin/env bash
# terraform/bootstrap.sh
# Run ONCE before `terraform init` to create the S3 backend bucket.
# Requires: aws CLI configured with account 616919332376
set -euo pipefail

AWS_REGION="ap-south-1"
BUCKET_NAME="boutique-tfstate-prod"

echo "1. Creating S3 bucket for Terraform state..."
aws s3api create-bucket \
  --bucket "${BUCKET_NAME}" \
  --region "${AWS_REGION}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION}"

echo "2. Enabling versioning (allows state history + recovery)..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "3. Enabling KMS encryption at rest..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms"
      }
    }]
  }'

echo "4. Blocking all public access..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "✅ Bootstrap complete."
echo "   State locking uses native S3 locking (Terraform >= 1.10, no DynamoDB needed)."
echo "   Now run: cd terraform/environments/prod && terraform init"
