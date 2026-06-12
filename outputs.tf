output "instance_id" {
  value = module.compute.instance_id
}

output "instance_public_ip" {
  value = module.compute.elastic_ip
}

output "instance_public_dns" {
  value = module.compute.public_dns
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_id" {
  value = module.network.public_subnet_id
}

output "security_group_id" {
  value = module.security_group.security_group_id
}

output "litestream_bucket_name" {
  description = "S3 bucket Litestream replicates SQLite to. Set as LITESTREAM_REPLICA_BUCKET in the backend host's .env."
  value       = module.backup.bucket_name
}

output "tcx_bucket_name" {
  description = "S3 bucket the backend stores uploaded TCX activity files in. Set as TCX_BUCKET_NAME in the backend host's .env."
  value       = module.tcx_storage.bucket_name
}

output "avatar_bucket_name" {
  description = "S3 bucket the backend stores uploaded user avatars in. Set as AVATAR_BUCKET_NAME in the backend host's .env."
  value       = module.avatar_storage.bucket_name
}

output "api_instance_profile_name" {
  description = "Instance profile attached to the backend EC2 instance. Listed for visibility; not needed at deploy time."
  value       = module.compute.instance_profile_name
}

output "github_actions_role_arn" {
  description = "Shared CI/CD role assumed by every repo's GitHub Actions. Set as the org-level AWS_GHA_ROLE_ARN secret."
  value       = module.github_oidc.role_arn
}
