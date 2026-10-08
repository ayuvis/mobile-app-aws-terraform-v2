output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "db_proxy_endpoint" {
  value = aws_db_proxy.main.endpoint
}

output "db_proxy_read_only_endpoint" {
  value = aws_db_proxy_endpoint.read_only.endpoint
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "media_cdn_domain" {
  value = aws_cloudfront_distribution.media.domain_name
}

output "waf_acl_arn" {
  value = aws_wafv2_web_acl.api.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  value = aws_iam_role.gha.arn
}

output "models_bucket" {
  value = aws_s3_bucket.models.bucket
}
