variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "project_name" {
  type    = string
  default = "prog-strength"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "availability_zone" {
  type    = string
  default = "us-east-2b"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "ami_name_pattern" {
  description = "AMI name with wildcards. Latest matching AMI is selected."
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
}

variable "ami_owner" {
  description = "AWS account ID that owns the AMI. 099720109477 = Canonical."
  type        = string
  default     = "099720109477"
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair (looked up via data source, not managed by TF)."
  type        = string
  default     = "prog-strength-backend-prod-keys"
}

variable "root_volume_size" {
  type    = number
  default = 8
}

variable "ingress_rules" {
  description = "Ingress rules for the API security group."
  type = list(object({
    description = string
    protocol    = string
    from_port   = number
    to_port     = number
    cidr_blocks = list(string)
  }))
  default = []
}
