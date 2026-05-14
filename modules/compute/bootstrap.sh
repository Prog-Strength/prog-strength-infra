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

# --- fastfetch (login banner) -----------------------------------------------
#
# Purely informational — prints host stats on interactive SSH login.
# Fastfetch is the actively-maintained successor to neofetch (which was
# archived upstream in 2024). It ships in Ubuntu 24.04's universe repo.

apt-get install -y fastfetch

# Run fastfetch on interactive login shells. /etc/profile.d/*.sh is sourced
# by /etc/profile for login shells, which SSH uses by default. The PS1
# guard skips non-interactive sessions (SCP, scripted SSH commands, etc).
cat > /etc/profile.d/fastfetch.sh <<'EOF'
if [ -n "$PS1" ] && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
EOF
chmod 0644 /etc/profile.d/fastfetch.sh

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
# Both repos are public, so no credentials are needed. Clones run as the
# ubuntu user so the working trees aren't root-owned (which would block the
# release workflow's `git pull` / `git checkout` over SSH).
#
# Directory layout matches what release.yml and deploy-caddy.yml SSH into:
#   /home/ubuntu/prog-strength-api    — api repo (cloned at HEAD of main)
#   /home/ubuntu/prog-strength-infra  — infra repo (Caddyfile lives here)

sudo -u ubuntu git clone "${api_repo_url}" /home/ubuntu/prog-strength-api
sudo -u ubuntu git clone "${infra_repo_url}" /home/ubuntu/prog-strength-infra

# SQLite data dir. docker-compose.yml bind-mounts `./data:/data` from the
# api working dir, so pre-creating it avoids the volume being root-owned
# the first time docker creates it implicitly.
sudo -u ubuntu mkdir -p /home/ubuntu/prog-strength-api/data

echo "Bootstrap complete. Host is ready for the next release deploy."
