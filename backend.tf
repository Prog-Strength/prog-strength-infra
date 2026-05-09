terraform {
  backend "s3" {
    bucket       = "prog-strength-terraform-backend"
    key          = "prod/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
