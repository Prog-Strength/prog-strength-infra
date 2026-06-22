#!/usr/bin/env bash
#
# On-host deploy for the api service. Invoked by prog-strength-api's
# release.yml / manual-deploy.yml via SSM Run Command (AWS-RunShellScript),
# replacing the old appleboy/ssh-action inline script. The released version
# tag is the only parameter the runner passes; all app secrets are read from
# Secrets Manager via the instance role and never transit the runner.
# Runs as the ubuntu user (the runner invokes `sudo -u ubuntu -H bash …`) so
# the infra checkout and ~/.docker creds keep their existing ownership.
# See prog-strength-docs/sows/ssm-deploys-retire-ssh.md.
set -euo pipefail

RELEASE_VERSION="${1:?usage: api.sh <version>  (e.g. v0.22.0 or 0.22.0)}"
RELEASE_VERSION="v${RELEASE_VERSION#v}" # normalize to a single leading v

AWS_REGION="us-east-2"
SECRET_ID="prog-strength-backend/prod/api"

cd /home/ubuntu/prog-strength-infra
git fetch --prune
git checkout main
git pull --ff-only

cd compose/api

# ECR login via the instance role (no static creds).
ECR_REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Render .env from Secrets Manager. The JSON blob's keys become KEY=value
# lines; absent optional providers (FatSecret, USDA, OpenAI/Anthropic) simply
# don't appear, so docker-compose's ${VAR:-} defaults apply and the endpoints
# degrade to 503 exactly as before. Deploy-orchestration values (region,
# version, registry) are non-secret and appended here, not stored in the blob.
umask 077
{
  aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" --region "${AWS_REGION}" \
    --query SecretString --output text \
    | jq -r 'to_entries[] | "\(.key)=\(.value)"'
  echo "AWS_REGION=${AWS_REGION}"
  echo "APP_VERSION=${RELEASE_VERSION}"
  echo "ECR_REGISTRY=${ECR_REGISTRY}"
} >.env

# Merge the monitoring stack so api + agent share the prog-strength network
# and Prometheus can scrape by service hostname (same as the SSH path).
COMPOSE_FILES=(-f docker-compose.yml -f /home/ubuntu/prog-strength-infra/monitoring/docker-compose.monitoring.yml)

# Pull the released image up-front so a missing/broken push surfaces before
# we tear down the running stack.
docker compose "${COMPOSE_FILES[@]}" pull api
docker compose "${COMPOSE_FILES[@]}" down
docker compose "${COMPOSE_FILES[@]}" up -d

echo "Deployed ${RELEASE_VERSION}"
docker compose "${COMPOSE_FILES[@]}" ps
docker compose "${COMPOSE_FILES[@]}" logs --tail=50
