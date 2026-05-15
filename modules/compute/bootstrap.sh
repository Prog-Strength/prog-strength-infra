#!/bin/bash
#
# Cloud-init bootstrap for the prog-strength api host. Runs once, as root,
# on first boot of a freshly-launched instance. Output streams to
# /var/log/cloud-init-output.log on the host — tail that file to debug.
#
# Idempotency note: this script is NOT designed to be re-run on an existing
# host. It assumes a clean Ubuntu image. The compute module pins user_data
# via `ignore_changes` so editing this file does not re-trigger it on the
# running instance.

set -euxo pipefail

# --- System update -----------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# --- Host operator tooling --------------------------------------------------
#
# sqlite3 CLI for ad-hoc inspection of the api's database at
# /home/ubuntu/prog-strength-api/data/app.db. The api itself doesn't need
# this — go-sqlite3 is statically linked into the binary — but having the
# CLI on the host means an SSH'd operator can run `sqlite3 -readonly ...`
# without first apt-installing anything.

apt-get install -y sqlite3

# --- Docker Engine + Compose v2 ---------------------------------------------
#
# Use Docker's official convenience script — it installs the engine and the
# compose plugin from Docker's apt repo, which tracks current versions
# (Ubuntu's `docker.io` package can lag by a major release).

curl -fsSL https://get.docker.com | sh

# Let the ubuntu user run docker without sudo. The release workflow SSHs in
# as ubuntu and calls `docker compose ...` directly, so this is required.
usermod -aG docker ubuntu

# --- Clone application + infra repos ----------------------------------------
#
# All repos are public, so no credentials are needed. Clones run as the
# ubuntu user so the working trees aren't root-owned (which would block
# the deploy workflows' `git pull` / `git checkout` over SSH).
#
# Directory layout matches what the deploy workflows SSH into:
#   /home/ubuntu/prog-strength-api    — api repo (release.yml)
#   /home/ubuntu/prog-strength-infra  — infra repo (deploy-caddy.yml)
#   /home/ubuntu/prog-strength-mcp    — mcp repo (deploy.yml)

sudo -u ubuntu git clone "${api_repo_url}" /home/ubuntu/prog-strength-api
sudo -u ubuntu git clone "${infra_repo_url}" /home/ubuntu/prog-strength-infra
sudo -u ubuntu git clone "${mcp_repo_url}" /home/ubuntu/prog-strength-mcp

# SQLite data dir. docker-compose.yml bind-mounts `./data:/data` from the
# api working dir, so pre-creating it avoids the volume being root-owned
# the first time docker creates it implicitly.
sudo -u ubuntu mkdir -p /home/ubuntu/prog-strength-api/data

# Shared docker network used by all services on this host. Both the api
# and mcp compose files declare it as `external: true` so they don't try
# to create or destroy it themselves — its lifecycle belongs here.
docker network create prog-strength 2>/dev/null || true

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
