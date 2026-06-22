# --- Backend runtime secrets (AWS Secrets Manager) --------------------------
#
# One JSON secret container per backend service, named
# prog-strength-backend/<env>/<service>. The prog-strength-backend/ prefix
# reads as clearly separate from prog-strength-developer/* (the autonomous
# developer's owner-private credentials); the /<env>/ segment means a future
# environment is prog-strength-backend/staging/* with no rename or IAM rework.
#
# Terraform owns the *containers*, their IAM, and (future) rotation policy —
# every backend resource stays in this repo. It deliberately does NOT own the
# *values*: there is no aws_secretsmanager_secret_version with real content,
# so plaintext never enters Terraform state (the same rule the developer
# repo's secrets.tf states explicitly). The values are seeded out-of-band
# from GitHub secrets by .github/workflows/seed-secrets.yml, and the host
# reads them at deploy time via its instance role. Hand-edits in the console
# are overwritten by the next seed — see each container's description.
#
# See prog-strength-docs/sows/ssm-deploys-retire-ssh.md.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  secret_name_prefix = "prog-strength-backend/${var.env}"
}

resource "aws_secretsmanager_secret" "backend" {
  for_each = var.services

  name        = "${local.secret_name_prefix}/${each.key}"
  description = each.value
}

# The host reads only its own environment's backend secrets via the instance
# role — never the developer family or a future environment. The default
# aws/secretsmanager KMS key needs no explicit kms:Decrypt for same-account
# use. Scoped to the /<env>/ path; the trailing /* matches the random suffix
# AWS appends to every secret ARN.
data "aws_iam_policy_document" "instance_secrets_read" {
  statement {
    sid       = "ReadBackendSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_name_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "instance_secrets_read" {
  name   = "prog-strength-backend-${var.env}-secrets-read"
  role   = var.instance_role_name
  policy = data.aws_iam_policy_document.instance_secrets_read.json
}
