variable "cluster_name" { type = string }
variable "cluster_version" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "project_name" { type = string }
variable "environment" { type = string }



# ── IAM: Cluster Role ──────────────────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── KMS Key for secrets encryption ────────────────────────────────────────────
resource "aws_kms_key" "eks" {
  description             = "EKS secrets encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "${var.cluster_name}-kms" }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}"
  target_key_id = aws_kms_key.eks.key_id
}

# ── Security Group: Cluster ────────────────────────────────────────────────────
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "${var.cluster_name}-cluster-sg"
    # Required so Karpenter's securityGroupSelectorTerms can discover this SG
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# ── EKS Cluster ────────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider { key_arn = aws_kms_key.eks.arn }
    resources = ["secrets"]
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ── OIDC Provider (required for IRSA + Karpenter) ─────────────────────────────
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ── Karpenter: IAM Role (IRSA) ─────────────────────────────────────────────────
# Karpenter controller runs in the cluster and calls EC2 APIs to launch nodes
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Karpenter needs to launch/terminate EC2 instances
        Sid    = "KarpenterEC2"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTopology",
          "pricing:GetProducts",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications"
        ]
        Resource = "*"
      },
      {
        # Pass IAM role to EC2 instances (node role)
        Sid      = "KarpenterPassRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        # Karpenter uses SQS for spot interruption handling
        Sid    = "KarpenterSQS"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        # EKS cluster access
        Sid      = "KarpenterEKS"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.this.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ── Karpenter: Node IAM Role ───────────────────────────────────────────────────
# EC2 instances launched by Karpenter assume this role
resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-profile"
  role = aws_iam_role.karpenter_node.name
}

# ── Karpenter: SQS Queue for Spot Interruption Handling ───────────────────────
# When AWS sends a spot interruption notice, Karpenter drains the node gracefully
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

# EventBridge rules to forward EC2 events to SQS
resource "aws_cloudwatch_event_rule" "karpenter_interruption_events" {
  for_each = {
    spot_interruption    = { source = "aws.ec2", detail_type = "EC2 Spot Instance Interruption Warning" }
    rebalance            = { source = "aws.ec2", detail_type = "EC2 Instance Rebalance Recommendation" }
    instance_state       = { source = "aws.ec2", detail_type = "EC2 Instance State-change Notification" }
    scheduled_change     = { source = "aws.health", detail_type = "AWS Health Event" }
  }

  name        = "${var.cluster_name}-karpenter-${each.key}"
  description = "Karpenter interruption event: ${each.key}"

  event_pattern = jsonencode({
    source      = [each.value.source]
    detail-type = [each.value.detail_type]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_interruption_sqs" {
  for_each  = aws_cloudwatch_event_rule.karpenter_interruption_events
  rule      = each.value.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ── Minimal Node Group for System Pods (CoreDNS, Karpenter itself) ─────────────
# Karpenter cannot launch itself — we need 2 small static nodes for system pods
# These are NOT scaled by Karpenter; they are fixed system nodes
resource "aws_iam_role" "system_node" {
  name = "${var.cluster_name}-system-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "system_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])
  role       = aws_iam_role.system_node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-system-ng"
  node_role_arn   = aws_iam_role.system_node.arn
  subnet_ids      = var.private_subnet_ids

  # t3.medium is enough for karpenter + coredns + kube-system pods
  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  labels = {
    "karpenter.sh/controller" = "true"
    "node-type"               = "system"
  }

  # IMPORTANT: Do NOT put a taint here.
  # A NoSchedule taint on system nodes blocks ALL workload pods from scheduling
  # until Karpenter is running and has launched workload nodes.
  # Karpenter and CoreDNS use nodeAffinity/nodeSelector to stay on system nodes,
  # not taints. Taints here cause pods to stay Pending on fresh cluster bootstrap.

  launch_template {
    id      = aws_launch_template.system_node.id
    version = aws_launch_template.system_node.latest_version
  }

  depends_on = [aws_iam_role_policy_attachment.system_node_policies]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_launch_template" "system_node" {
  name_prefix = "${var.cluster_name}-system-node-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.cluster_name}-system-node"
      Environment = var.environment
    }
  }
}

# ── EKS Add-ons ────────────────────────────────────────────────────────────────
resource "aws_eks_addon" "addons" {
  for_each = {
    "vpc-cni"            = "v1.18.3-eksbuild.1"
    "coredns"            = "v1.11.3-eksbuild.1"
    "kube-proxy"         = "v1.32.0-eksbuild.1"
    "aws-ebs-csi-driver" = "v1.37.0-eksbuild.1"
  }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = aws_eks_cluster.this.name
}
output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}
output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}
output "karpenter_node_role_arn" {
  value = aws_iam_role.karpenter_node.arn
}
output "karpenter_node_instance_profile_name" {
  value = aws_iam_instance_profile.karpenter_node.name
}
output "karpenter_controller_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}
output "karpenter_interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interruption.name
}
output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}
output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}
