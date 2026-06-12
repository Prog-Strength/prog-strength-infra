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
  description = "Litestream S3 replica bucket + IAM role/profile config. The bucket holds SQLite WAL frames and snapshots; the IAM role is attached to the backend EC2 instance so Litestream authenticates without static keys."
  type = object({
    bucket_name                        = string
    noncurrent_version_expiration_days = number
  })
  default = {
    bucket_name                        = "prog-strength-database-backups"
    noncurrent_version_expiration_days = 30
  }
}

variable "tcx_storage" {
  description = "TCX activity file uploads S3 bucket config. The bucket holds uploaded TCX files; an IAM policy scoped to it is attached to the backend EC2 instance role so the backend authenticates without static keys."
  type = object({
    bucket_name                        = string
    noncurrent_version_expiration_days = number
  })
  default = {
    bucket_name                        = "prog-strength-tcx-uploads"
    noncurrent_version_expiration_days = 30
  }
}

variable "avatar_storage" {
  description = "User avatar uploads S3 bucket config. The bucket holds uploaded avatar images; an IAM policy scoped to it is attached to the backend EC2 instance role so the backend authenticates without static keys. Reaping of superseded objects is by lifecycle rule on objects tagged avatar-status=orphaned (not age-based)."
  type = object({
    bucket_name            = string
    orphan_expiration_days = number
  })
  default = {
    bucket_name            = "prog-strength-avatars"
    orphan_expiration_days = 7
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
      infra_repo_url = string
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
      infra_repo_url = "https://github.com/Prog-Strength/prog-strength-infra.git"
    }
  }
}

variable "ecr" {
  description = "ECR repositories that hold images built by GitHub Actions and pulled by the EC2 host at deploy time. One repo per service so lifecycle policies and tag immutability scope correctly per image."
  type = object({
    repository_names           = list(string)
    max_image_count            = number
    untagged_image_expire_days = number
  })
  default = {
    repository_names           = ["api", "mcp", "agent"]
    max_image_count            = 10
    untagged_image_expire_days = 1
  }
}

variable "logging" {
  description = "CloudWatch Logs setup for the docker-compose service containers. service_names becomes one log group each (/prog-strength/<name>). retention_days bounds storage cost; monthly_budget_usd is the EstimatedCharges alarm threshold (set to 0 to skip the alarm). See prog-strength-docs/sows/cloudwatch-logs.md."
  type = object({
    service_names      = list(string)
    retention_days     = number
    monthly_budget_usd = number
  })
  default = {
    service_names      = ["api", "agent", "mcp"]
    retention_days     = 30
    monthly_budget_usd = 5
  }
}

variable "github_oidc" {
  description = "Shared GitHub Actions OIDC CI/CD role. One role for every Prog Strength repo's workflows — see prog-strength-docs/sows/github-actions-oidc-role.md. oidc_thumbprints must match the existing (imported) provider; fetch with `aws iam get-open-id-connect-provider`."
  type = object({
    oidc_thumbprints = list(string)
  })
}
