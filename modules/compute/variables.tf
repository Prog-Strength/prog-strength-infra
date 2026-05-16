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
  description = "Repos cloned into the EC2 host by user_data on first boot. All must be reachable without auth from the instance."
  type = object({
    api_repo_url   = string
    infra_repo_url = string
    mcp_repo_url   = string
    agent_repo_url = string
  })
}

variable "iam_instance_profile_name" {
  description = "Instance profile attached to the API instance, used by Litestream (and any future host-side AWS clients) to authenticate without static keys. Sourced from the backup module."
  type        = string
}
