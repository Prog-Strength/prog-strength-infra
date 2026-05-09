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
