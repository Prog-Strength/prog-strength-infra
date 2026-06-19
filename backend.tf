# The state `key` is supplied at init time via `-backend-config` so the
# same code targets a per-environment state file under this application's
# prefix: prog-strength-backend/<env>/terraform.tfstate. CI defaults the
# env to prod; dev/stg are enabled by setting TF_STATE_ENV.
terraform {
  backend "s3" {
    bucket       = "prog-strength-terraform-backend"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
