output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "karpenter_controller_role_arn" {
  value = module.eks.karpenter_controller_role_arn
}

output "karpenter_node_instance_profile_name" {
  value = module.eks.karpenter_node_instance_profile_name
}

output "karpenter_interruption_queue_name" {
  value = module.eks.karpenter_interruption_queue_name
}
