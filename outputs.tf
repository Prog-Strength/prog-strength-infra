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
  description = "S3 bucket Litestream replicates SQLite to. Set as LITESTREAM_REPLICA_BUCKET in the API host's .env."
  value       = module.backup.bucket_name
}

output "api_instance_profile_name" {
  description = "Instance profile attached to the API EC2 instance. Listed for visibility; not needed at deploy time."
  value       = module.backup.instance_profile_name
}
