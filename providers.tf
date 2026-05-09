provider "aws" {
  region = var.aws.region

  default_tags {
    tags = {
      Project     = var.project.name
      Environment = var.project.environment
      ManagedBy   = "prog-strength-infra"
    }
  }
}
