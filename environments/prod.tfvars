########################################
# Prog Strength Production Environment #
########################################

# --- Project Configurations ---

project = {
  name        = "prog-strength"
  environment = "prod"
}

# --- AWS Environment Configurations ---

aws = {
  region            = "us-east-2"
  availability_zone = "us-east-2b"
}

# --- Network Configurations ---

network = {
  vpc_cidr           = "10.0.0.0/16"
  public_subnet_cidr = "10.0.1.0/24"
}

# --- Backup Configurations (Litestream → S3) ---

backup = {
  # Globally-unique bucket name; the API host's litestream.yml references
  # this same value via the LITESTREAM_REPLICA_BUCKET env var. Versioned
  # + lifecycled inside the module.
  bucket_name                        = "prog-strength-database-backups"
  noncurrent_version_expiration_days = 30
}

# --- TCX Storage Configurations (activity file uploads → S3) ---

tcx_storage = {
  # Globally-unique bucket name; the backend references this same value via
  # the TCX_BUCKET_NAME env var. Versioned + lifecycled inside the module.
  bucket_name                        = "prog-strength-tcx-uploads"
  noncurrent_version_expiration_days = 30
}

# --- Compute Configurations (API & Database) ---

compute = {
  instance_type    = "t4g.small" # This is a primary cost factor, right-size carefully
  ami_name_pattern = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"
  ami_owner        = "099720109477"
  ssh_key_name     = "prog-strength-backend-prod-keys"
  # Disk usage at steady state is roughly:
  #   Docker images       ~3 GB   (Grafana alone is ~900 MB)
  #   Build cache         ~1.5 GB (Go builds; grows back after every deploy)
  #   Ubuntu base + logs  ~1.2 GB
  #   SQLite + Prom data  ~250 MB
  # 20 GB gives ~14 GB headroom — comfortable for years of beta scale
  # without absorbing every build/cache spike into an alert.
  root_volume_size = 20
  security_group = {
    ingress_rules = [
      {
        description = "SSH"
        protocol    = "tcp"
        from_port   = 22
        to_port     = 22
        cidr_blocks = ["0.0.0.0/0"]
      },
      {
        description = "HTTP (Caddy ACME challenge + redirect)"
        protocol    = "tcp"
        from_port   = 80
        to_port     = 80
        cidr_blocks = ["0.0.0.0/0"]
      },
      {
        description = "HTTPS"
        protocol    = "tcp"
        from_port   = 443
        to_port     = 443
        cidr_blocks = ["0.0.0.0/0"]
      },
    ]
  }
  bootstrap = {
    # Only the infra repo is cloned on first boot — it owns all
    # orchestration manifests (compose files, Caddyfile, monitoring
    # config, litestream.yml). Service images come from ECR.
    infra_repo_url = "https://github.com/Prog-Strength/prog-strength-infra.git"
  }
}

# --- ECR (image registry for GitHub Actions-built service images) -----------

ecr = {
  # One repository per service. Each lands at
  # <project>-<env>/<name> in ECR (e.g. prog-strength-prod/api).
  repository_names = ["api", "mcp", "agent"]
  # Tagged-image retention. ~10 versions covers a few months of
  # rollback at the project's release cadence; bump if longer
  # rollback history starts to matter.
  max_image_count = 10
  # Untagged images are build leftovers — short retention is fine.
  untagged_image_expire_days = 1
}
