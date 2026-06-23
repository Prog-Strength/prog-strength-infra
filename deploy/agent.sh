#!/usr/bin/env bash
#
# On-host deploy for the agent service. Invoked by prog-strength-agent's
# release.yml / manual-deploy.yml via SSM Run Command. Version tag is the only
# runner parameter; secrets (ANTHROPIC_API_KEY, OPENAI_API_KEY, JWT_SIGNING_KEY)
# come from Secrets Manager via the instance role, and non-secret config
# (CORS_ALLOWED_ORIGINS) from the committed compose/agent/config.env. Runs as
# the ubuntu user. See prog-strength-docs/sows/ssm-deploys-retire-ssh.md.
set -euo pipefail

RELEASE_VERSION="${1:?usage: agent.sh <version>  (e.g. v0.1.0 or 0.1.0)}"
RELEASE_VERSION="v${RELEASE_VERSION#v}"

AWS_REGION="us-east-2"
SECRET_ID="prog-strength-backend/prod/agent"

cd /home/ubuntu/prog-strength-infra
git fetch --prune
git checkout main
git pull --ff-only

cd compose/agent

ECR_REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Optional OPENAI_API_KEY absent from the blob → /speak returns 503; the agent
# still boots and /chat + /title keep working (same degrade as before).
umask 077
{
  # Non-secret config first (CORS_ALLOWED_ORIGINS); committed at
  # compose/agent/config.env. Secret-derived lines and deploy echoes follow
  # and never collide (disjoint keys).
  cat config.env
  aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" --region "${AWS_REGION}" \
    --query SecretString --output text \
    | jq -r 'to_entries[] | "\(.key)=\(.value)"'
  echo "AWS_REGION=${AWS_REGION}"
  echo "APP_VERSION=${RELEASE_VERSION}"
  echo "ECR_REGISTRY=${ECR_REGISTRY}"
} >.env

# Fail loud BEFORE tearing down the running stack if a required value is
# missing/empty. An empty CORS_ALLOWED_ORIGINS silently disables the agent's
# CORS middleware (the `if config.cors_allowed_origins:` guard in server.py),
# which 405s the browser's OPTIONS preflight — exactly the regression this
# guards against. Inline for now; deploy/lib/require-env.sh (PR #49) replaces
# this once merged.
for k in CORS_ALLOWED_ORIGINS ANTHROPIC_API_KEY JWT_SIGNING_KEY; do
  if ! grep -q "^${k}=." .env; then
    echo "Refusing to deploy: required key ${k} is missing or empty in .env" >&2
    exit 1
  fi
done

docker compose pull agent
docker compose down
docker compose up -d

echo "Deployed ${RELEASE_VERSION}"
docker compose ps
docker compose logs --tail=50
