terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  backend "s3" {
    bucket         = "boutique-tfstate-prod"
    key            = "prod/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "boutique-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "online-boutique"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
}

module "vpc" {
  source = "../../modules/vpc"

  name            = local.cluster_name
  cidr            = var.vpc_cidr
  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs
  cluster_name    = local.cluster_name
}

module "ecr" {
  source = "../../modules/ecr"

  services     = var.services
  project_name = var.project_name
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.cluster_name
  cluster_version    = var.eks_cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  project_name       = var.project_name
  environment        = var.environment
}
