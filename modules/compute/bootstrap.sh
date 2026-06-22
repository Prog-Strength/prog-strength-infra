#!/bin/bash
#
# Cloud-init bootstrap for the prog-strength backend host. Runs once, as root,
# on first boot of a freshly-launched instance. Output streams to
# /var/log/cloud-init-output.log on the host — tail that file to debug.
#
# Idempotency note: this script is NOT designed to be re-run on an existing
# host. It assumes a clean Ubuntu image. The compute module pins user_data
# via `ignore_changes` so editing this file does not re-trigger it on the
# running instance.

# Linter note: this file is a Terraform templatefile(), not a standalone
# script, so the SC2154/SC2034 disable below silences two template
# artifacts (not bugs):
#   - `${infra_repo_url}` is a Terraform interpolation injected at render
#     time, which the linter reads as an unassigned variable (SC2154).
#   - `$${aws_arch}` / `$${ff_arch}` are Terraform-escaped `$$` shell
#     references; the linter sees the `$$` (PID) and misses the use, so it
#     reports the assignments as unused (SC2034).
# Every other rule stays active on the rest of the script.
# shellcheck disable=SC2154,SC2034

set -euxo pipefail

# --- System update -----------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# --- Host operator tooling --------------------------------------------------
#
# sqlite3 CLI for ad-hoc inspection of the api's database at
# /home/ubuntu/prog-strength-infra/compose/api/data/app.db. The api itself
# doesn't need this — go-sqlite3 is statically linked into the binary —
# but having the CLI on the host means an SSH'd operator can run
# `sqlite3 -readonly ...` without first apt-installing anything.
#
# jq is for the on-host deploy scripts (deploy/*.sh): they render each
# service's compose .env from the Secrets Manager JSON blob via
# `jq -r 'to_entries[] | "\(.key)=\(.value)"'`, so it must be present
# system-wide before the first SSM deploy runs.

apt-get install -y sqlite3 jq

# AWS CLI v2 for ECR login at deploy time. The deploy workflows SSH in
# and run `aws ecr get-login-password | docker login ...` against the
# host's instance role (no static creds), so awscli must be present
# system-wide for the ubuntu user's shell. Installed via the official
# bundle rather than apt — apt ships v1, and the v2 bundle is what AWS
# documents and supports going forward.
arch="$(dpkg --print-architecture)"
case "$arch" in
    arm64) aws_arch=aarch64 ;;
    amd64) aws_arch=x86_64  ;;
    *) echo "awscli: unsupported arch $arch"; exit 1 ;;
esac
curl -fsSL -o /tmp/awscliv2.zip \
    "https://awscli.amazonaws.com/awscli-exe-linux-$${aws_arch}.zip"
apt-get install -y unzip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# --- Docker Engine + Compose v2 ---------------------------------------------
#
# Use Docker's official convenience script — it installs the engine and the
# compose plugin from Docker's apt repo, which tracks current versions
# (Ubuntu's `docker.io` package can lag by a major release).

curl -fsSL https://get.docker.com | sh

# Let the ubuntu user run docker without sudo. The release workflow SSHs in
# as ubuntu and calls `docker compose ...` directly, so this is required.
usermod -aG docker ubuntu

# --- Clone the infra repo ---------------------------------------------------
#
# Service images are built and pushed to ECR by each service's GitHub
# Actions workflow — the host only needs orchestration manifests, not
# source code. All compose files, Caddyfile, Prometheus/Grafana config,
# and litestream.yml now live under prog-strength-infra/compose/ and
# friends, so this single clone is everything the host needs to operate.
#
# Public repo, so no credentials are required. Clone as the ubuntu user
# so the working tree isn't root-owned (which would block the deploy
# workflows' `git pull` over SSH).

sudo -u ubuntu git clone "${infra_repo_url}" /home/ubuntu/prog-strength-infra

# SQLite data dir. The api compose file bind-mounts `./data:/data` from
# compose/api/, so pre-creating it avoids the volume being root-owned the
# first time docker creates it implicitly. Litestream's restore services
# will populate app.db and telemetry.db from S3 on first boot if their
# replicas exist.
sudo -u ubuntu mkdir -p /home/ubuntu/prog-strength-infra/compose/api/data

# Shared docker network. All three service stacks (api, mcp, agent)
# declare it as `external: true` so they don't try to create or destroy
# it themselves — its lifecycle belongs here.
docker network create prog-strength 2>/dev/null || true

# --- SSM agent (deploy transport + break-glass shell) -----------------------
#
# Deploys run through SSM Run Command and operators break-glass via SSM
# Session Manager — there is NO inbound SSH. Recent Ubuntu AMIs ship
# amazon-ssm-agent preinstalled via snap; enable + start it explicitly so a
# freshly-bootstrapped host registers as a managed node with no manual step.
# The instance role (AmazonSSMManagedInstanceCore, attached in
# modules/compute/iam.tf) is what authorizes registration. Best-effort across
# snap/systemd packagings so this never fails the bootstrap.
snap start amazon-ssm-agent 2>/dev/null \
  || systemctl enable --now amazon-ssm-agent 2>/dev/null \
  || true

# --- fastfetch (login banner) -----------------------------------------------
#
# Purely cosmetic — prints host stats on interactive SSH login. Installed
# from the upstream GitHub release because fastfetch isn't packaged in
# Ubuntu 24.04 LTS. The whole block is best-effort: if the download or
# install fails, the bootstrap still succeeds and the host is fully
# functional — you just don't get the banner.

set +e
(
    set -e
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        arm64) ff_arch=aarch64 ;;
        amd64) ff_arch=amd64   ;;
        *) echo "fastfetch: unsupported arch $arch, skipping"; exit 0 ;;
    esac

    curl -fsSL -o /tmp/fastfetch.deb \
        "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-$${ff_arch}.deb"
    apt-get install -y /tmp/fastfetch.deb
    rm -f /tmp/fastfetch.deb

    # Run fastfetch on interactive login shells. /etc/profile.d/*.sh is
    # sourced by /etc/profile for login shells, which SSH uses by default.
    # The PS1 guard skips non-interactive sessions (SCP, scripted SSH).
    cat > /etc/profile.d/fastfetch.sh <<'PROFILE'
if [ -n "$PS1" ] && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
PROFILE
    chmod 0644 /etc/profile.d/fastfetch.sh
) || echo "fastfetch install failed, continuing without login banner"
set -e

echo "Bootstrap complete. Host is ready for the next release deploy."
