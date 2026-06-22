#!/usr/bin/env bash
#
# On-host deploy for the mcp service. Invoked by prog-strength-mcp's
# release.yml / manual-deploy.yml via SSM Run Command. The mcp server holds no
# app secrets (auth comes from the agent's per-request Authorization header),
# so prog-strength-backend/prod/mcp is currently an empty {} blob — fetched
# here for a uniform deploy path and so a future mcp secret is a seed-list
# addition, not a script change. Runs as the ubuntu user.
# See prog-strength-docs/sows/ssm-deploys-retire-ssh.md.
set -euo pipefail

RELEASE_VERSION="${1:?usage: mcp.sh <version>  (e.g. v0.1.0 or 0.1.0)}"
RELEASE_VERSION="v${RELEASE_VERSION#v}"

AWS_REGION="us-east-2"
SECRET_ID="prog-strength-backend/prod/mcp"

cd /home/ubuntu/prog-strength-infra
git fetch --prune
git checkout main
git pull --ff-only

cd compose/mcp

ECR_REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

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

docker compose pull mcp
docker compose down
docker compose up -d

echo "Deployed ${RELEASE_VERSION}"
docker compose ps
docker compose logs --tail=50
