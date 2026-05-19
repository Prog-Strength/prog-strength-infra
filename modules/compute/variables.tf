variable "name_prefix" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_type" {
  type = string
}

variable "ami_name_pattern" {
  type = string
}

variable "ami_owner" {
  type = string
}

variable "ssh_key_name" {
  type = string
}

variable "root_volume_size" {
  type = number
}

variable "bootstrap" {
  description = "Infra repo cloned into the EC2 host by user_data on first boot. Service images come from ECR; only orchestration manifests (compose, caddy, monitoring) need to be present on disk."
  type = object({
    infra_repo_url = string
  })
}
