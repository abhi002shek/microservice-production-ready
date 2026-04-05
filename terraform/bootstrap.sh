# Terraform S3 backend bootstrap
# Run this ONCE before terraform init
# This creates the S3 bucket and DynamoDB table for remote state

AWS_REGION="ap-south-1"
BUCKET_NAME="boutique-tfstate-prod"
DYNAMO_TABLE="boutique-tfstate-lock"

echo "Creating S3 bucket for Terraform state..."
aws s3api create-bucket \
  --bucket ${BUCKET_NAME} \
  --region ${AWS_REGION} \
  --create-bucket-configuration LocationConstraint=${AWS_REGION}

aws s3api put-bucket-versioning \
  --bucket ${BUCKET_NAME} \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket ${BUCKET_NAME} \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms"
      }
    }]
  }'

aws s3api put-public-access-block \
  --bucket ${BUCKET_NAME} \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "Creating DynamoDB table for state locking..."
aws dynamodb create-table \
  --table-name ${DYNAMO_TABLE} \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${AWS_REGION}

echo "✅ Backend bootstrap complete"
