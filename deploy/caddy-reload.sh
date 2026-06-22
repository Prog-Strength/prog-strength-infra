#!/usr/bin/env bash
#
# On-host Caddy reload. Invoked by prog-strength-infra's deploy-caddy.yml via
# SSM Run Command when only the Caddyfile changes. Pulls the latest infra
# checkout (Caddyfile lives in caddy/) and reloads Caddy in place so the
# Let's Encrypt certs + ACME account key in the caddy_data volume survive and
# live connections aren't dropped. Caddy runs as a service in the api compose
# project (compose/api/docker-compose.yml). Runs as the ubuntu user.
# See prog-strength-docs/sows/ssm-deploys-retire-ssh.md.
set -euo pipefail

cd /home/ubuntu/prog-strength-infra
git fetch --prune
git checkout main
git pull --ff-only

cd compose/api
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
docker compose ps caddy
