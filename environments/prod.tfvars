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

# --- Avatar Storage Configurations (user avatar uploads → S3) ---

avatar_storage = {
  # Globally-unique bucket name; the backend references this same value via
  # the AVATAR_BUCKET_NAME env var. Not versioned (latest-wins via distinct
  # UUID keys). The lifecycle rule expires ONLY objects the API tags
  # avatar-status=orphaned after this many days — current avatars are
  # untagged and never reaped.
  bucket_name            = "prog-strength-avatars"
  orphan_expiration_days = 7
}

# --- Activity Photo Storage Configurations (activity photo uploads → S3) ---

activity_photo_storage = {
  # Globally-unique bucket name; the backend references this same value via
  # the PHOTO_BUCKET_NAME env var. Not versioned (latest-wins via distinct
  # UUID keys). The lifecycle rule expires ONLY objects the API tags
  # photo-status=orphaned after this many days — current photos are
  # untagged and never reaped.
  bucket_name            = "prog-strength-activity-photos"
  orphan_expiration_days = 7
}

activity_video_storage = {
  # Globally-unique bucket name; the backend references this same value via the
  # VIDEO_BUCKET_NAME env var. Separate from the photo bucket so CORS,
  # lifecycle, and cost are addressable independently.
  bucket_name = "prog-strength-activity-videos"
  # The browser PUTs video bytes straight here, so S3 answers the CORS
  # preflight itself. Mirrors the API's own cors.allowed_origins — production
  # plus the Vercel preview wildcard. A missing origin here surfaces as an
  # opaque browser CORS failure while curl against the same URL succeeds.
  cors_allowed_origins = [
    "https://progstrength.fitness",
    "https://prog-strength-web-*-jimmy-wallaces-projects.vercel.app",
  ]
  # Expires ONLY objects the API tags video-status=orphaned: abandoned
  # reservations, oversize rejects, and deleted videos. Current videos are
  # untagged and never reaped.
  orphan_expiration_days = 7
  # Interrupted multipart uploads leave billable parts invisible to a normal
  # listing; abort them after this many days.
  abort_incomplete_multipart_days = 3
}

# --- Compute Configurations (API & Database) ---

compute = {
  # This is a primary cost factor, right-size carefully. Bumped small -> medium
  # (2 GB -> 4 GB) when the API started serving activity photos and video: the
  # host holds request/response buffers for media alongside the API, MCP, agent,
  # Caddy, Prometheus and Grafana, and 2 GB left no room for that. vCPU count is
  # unchanged (2); medium also doubles the CPU-credit accrual (24/hr vs 12/hr),
  # which covers the encode/transfer bursts media traffic arrives in.
  instance_type = "t4g.medium"
  # Ubuntu 26.04 LTS (Resolute Raccoon). Moved off 24.04 noble during the
  # instance resize, since that already required a deliberate host
  # replacement — see the replacement checklist in CONTRIBUTING.md. The
  # trailing `*` plus `most_recent = true` tracks the newest 26.04 build,
  # but `lifecycle.ignore_changes = [ami]` means a new publish never
  # recycles the live host on its own.
  ami_name_pattern = "ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-arm64-server-*"
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
    # Note: the module only reads cidr_blocks[0] of each rule, and keys the
    # rules by description — so a second source CIDR means a second entry
    # with its own unique description, not another element here.
    ingress_rules = [
      {
        description = "HTTP (Caddy ACME challenge + redirect)"
        protocol    = "tcp"
        from_port   = 80
        to_port     = 80
        cidr_blocks = ["0.0.0.0/0"]
      },
      {
        # Inbound SSH, reopened by operator decision. This reverses the
        # posture set by prog-strength-docs/sows/ssm-deploys-retire-ssh.md,
        # which closed port 22 because both deploy paths dial OUT to AWS
        # over 443: deploys still run via SSM Run Command and break-glass
        # via SSM Session Manager, so nothing in CI depends on this rule.
        # It exists purely for direct operator SSH.
        #
        # Scoped to 0.0.0.0/0, so sshd is exposed to the internet-wide
        # scanners that sweep every public IPv4 continuously. What stands
        # between them and the host is key-only auth — Ubuntu's cloud image
        # ships PasswordAuthentication no, and the only authorized key is
        # the one cloud-init installs from the `ssh_key_name` key pair. If
        # that ever changes, this rule becomes the exposure.
        description = "SSH (direct operator access)"
        protocol    = "tcp"
        from_port   = 22
        to_port     = 22
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

# --- Backend runtime secrets (Secrets Manager, infra-owned, GitHub-seeded) --

secrets = {
  # One JSON secret container per backend service under
  # prog-strength-backend/prod/<service>. Values are seeded from GitHub
  # secrets by .github/workflows/seed-secrets.yml and are never stored in
  # Terraform state. The description on each container documents its purpose
  # and infra-seeded origin so the console reader knows hand-edits get
  # overwritten by the next seed.
  services = {
    api   = "Backend prod app config for the api service. Values seeded from GitHub secrets by prog-strength-infra/seed-secrets.yml; not stored in Terraform state. Consumed by the api container's .env at deploy time."
    mcp   = "Backend prod app config for the mcp service. Values seeded from GitHub secrets by prog-strength-infra/seed-secrets.yml; not stored in Terraform state. Consumed by the mcp container's .env at deploy time."
    agent = "Backend prod app config for the agent service. Values seeded from GitHub secrets by prog-strength-infra/seed-secrets.yml; not stored in Terraform state. Consumed by the agent container's .env at deploy time."
  }
}

# --- GitHub Actions OIDC (shared CI/CD role) ---------------------------------

github_oidc = {
  # Must match the existing provider exactly (import is a no-op then).
  # GitHub's OIDC TLS chain; AWS treats these as advisory for
  # token.actions.githubusercontent.com but the API requires the field.
  oidc_thumbprints = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
