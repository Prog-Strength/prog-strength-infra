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
