output "instance_id" {
  value = aws_instance.backend.id
}

output "elastic_ip" {
  value = aws_eip.api.public_ip
}

output "public_dns" {
  value = aws_eip.api.public_dns
}

output "instance_role_name" {
  description = "Name of the IAM role attached to the EC2 instance. Domain modules (backup, ecr) attach their own managed/inline policies to this role rather than expanding the compute module's responsibilities."
  value       = aws_iam_role.api_instance.name
}

output "instance_profile_name" {
  description = "Instance profile attached to the backend EC2 instance. Mostly here so the root-level output can re-expose it for AWS console convenience; the compute module attaches the profile to its own instance internally."
  value       = aws_iam_instance_profile.api.name
}
