variable "name_prefix" {
  description = "Prefix for repository names — typically <project>-<environment>. Each repo lands at <name_prefix>/<service>."
  type        = string
}

variable "repository_names" {
  description = "Service names that get their own ECR repository. Each becomes `<name_prefix>/<name>`."
  type        = list(string)
}

variable "max_image_count" {
  description = "How many of the most recent tagged images each repository keeps before lifecycle policy expires older ones. Caps long-term storage growth while preserving a rollback window."
  type        = number
  default     = 10
}

variable "untagged_image_expire_days" {
  description = "How long an untagged image lives before being expired. Untagged images are usually build leftovers — short retention is fine."
  type        = number
  default     = 1
}

variable "instance_role_name" {
  description = "Name of the IAM role attached to the EC2 instance, owned by the compute module. This module attaches AWS-managed AmazonEC2ContainerRegistryReadOnly to it so docker compose on the host can pull images from these repositories."
  type        = string
}
