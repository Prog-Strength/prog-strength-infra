variable "project" {
  description = "Project identity used for tags and resource naming."
  type = object({
    name        = string
    environment = string
  })
  default = {
    name        = "prog-strength"
    environment = "prod"
  }
}

variable "aws" {
  description = "AWS region and AZ for all resources."
  type = object({
    region            = string
    availability_zone = string
  })
  default = {
    region            = "us-east-2"
    availability_zone = "us-east-2b"
  }
}

variable "network" {
  description = "VPC and subnet CIDRs."
  type = object({
    vpc_cidr           = string
    public_subnet_cidr = string
  })
  default = {
    vpc_cidr           = "10.0.0.0/16"
    public_subnet_cidr = "10.0.1.0/24"
  }
}

variable "backup" {
  description = "Litestream S3 replica bucket + IAM role/profile config. The bucket holds SQLite WAL frames and snapshots; the IAM role is attached to the API EC2 instance so Litestream authenticates without static keys."
  type = object({
    bucket_name                        = string
    noncurrent_version_expiration_days = number
  })
  default = {
    bucket_name                        = "prog-strength-database-backups"
    noncurrent_version_expiration_days = 30
  }
}

variable "compute" {
  description = "EC2 instance config and the security group rules attached to it."
  type = object({
    instance_type    = string
    ami_name_pattern = string
    ami_owner        = string
    ssh_key_name     = string
    root_volume_size = number
    security_group = object({
      ingress_rules = list(object({
        description = string
        protocol    = string
        from_port   = number
        to_port     = number
        cidr_blocks = list(string)
      }))
    })
    bootstrap = object({
      api_repo_url   = string
      infra_repo_url = string
      mcp_repo_url   = string
    })
  })
  default = {
    instance_type    = "t4g.small"
    ami_name_pattern = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
    ami_owner        = "099720109477"
    ssh_key_name     = "prog-strength-backend-prod-keys"
    root_volume_size = 8
    security_group = {
      ingress_rules = []
    }
    bootstrap = {
      api_repo_url   = "https://github.com/Prog-Strength/prog-strength-api.git"
      infra_repo_url = "https://github.com/Prog-Strength/prog-strength-infra.git"
      mcp_repo_url   = "https://github.com/Prog-Strength/prog-strength-mcp.git"
    }
  }
}
