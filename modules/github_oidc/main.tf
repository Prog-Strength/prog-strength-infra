# --- Shared GitHub Actions OIDC role for ALL Prog Strength CI/CD ------------
#
# One role, assumed by every repository's workflows via GitHub's OIDC
# provider — the deliberate operational stance is "every repo's GHA uses
# the same CI/CD role" (see prog-strength-docs/sows/github-actions-oidc-role.md).
# Short-lived federated credentials replace the long-lived IAM user keys
# that previously sat in four repos' secrets.
#
# The permission policy is the union of what the workflows do:
#   - terraform plan/apply for this repo's stack
#   - ECR image push from api/agent/mcp releases
#   - prog-strength-developer's platform ops (EC2 workers, SSM, secrets reads)
# Mutating IAM access is fenced to prog-strength-* resource prefixes so a
# stolen CI token can manage this project's infrastructure but cannot
# escalate to account takeover.

data "aws_caller_identity" "current" {}

# The provider predates this module (created manually; also read by
# prog-strength-developer's data source). It is IMPORTED, not recreated —
# see the import block in the root module's imports.tf.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.oidc_thumbprints
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # main-branch contexts for every trusted repo, plus pull_request
    # contexts only where terraform plan runs on PRs. Fork PRs never get
    # OIDC tokens from GitHub, so the pull_request subjects are only
    # mintable from same-repo branches.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = concat(
        [for r in var.main_branch_repos : "repo:${var.github_org}/${r}:ref:refs/heads/main"],
        [for r in var.pull_request_repos : "repo:${var.github_org}/${r}:pull_request"],
      )
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "permissions" {
  # EC2/VPC: this repo's terraform owns the whole network + instance stack
  # (VPC, subnets, IGW, route tables, SGs, instance, EIP, volumes);
  # developer CI runs/terminates worker instances and manages launch
  # templates. Service-level grant — most EC2 networking actions don't
  # honor resource-ARN conditions cleanly (same reasoning as the
  # EC2ManagerInfra statement in developer's previous role).
  statement {
    sid       = "EC2"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # GetAuthorizationToken only works against "*".
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Image push from release workflows + repository/lifecycle management
  # from this repo's ecr module. Fenced to prog-strength-* repositories
  # (covers prog-strength-prod/* and any future environment prefix).
  statement {
    sid       = "ECRRepositories"
    actions   = ["ecr:*"]
    resources = ["arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/prog-strength-*"]
  }

  # Terraform state (prog-strength-terraform-backend — used by both infra
  # and developer stacks) plus the litestream/tcx/avatar data buckets this
  # repo manages. Fenced by bucket name prefix.
  statement {
    sid     = "S3"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::prog-strength-*",
      "arn:aws:s3:::prog-strength-*/*",
    ]
  }

  # Read-only IAM everywhere: terraform refresh of roles, profiles,
  # policies, and the OIDC provider data source in developer's stack.
  statement {
    sid       = "IAMRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Mutating IAM fenced to prog-strength-* names. Covers this repo's
  # instance role/profile/policies, developer's worker+manager roles, and
  # this role itself (so future policy updates apply from CI rather than
  # requiring an admin re-bootstrap — the trust policy already restricts
  # who can assume the role, so self-PutRolePolicy adds no new principal).
  statement {
    sid = "IAMManageProjectResources"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/prog-strength-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/prog-strength-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/prog-strength-*",
    ]
  }

  # PassRole fenced the same way: the backend instance role and
  # developer's worker/manager roles are passed to EC2 at apply time.
  statement {
    sid       = "IAMPassProjectRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/prog-strength-*"]
  }

  # Drift management on the imported provider only. Deliberately NO
  # Create/Delete — CI must never be able to delete the provider that
  # its own trust depends on.
  statement {
    sid = "OIDCProviderManage"
    actions = [
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
    ]
    resources = [aws_iam_openid_connect_provider.github.arn]
  }

  # Log groups + retention from this repo's logging module; stream reads
  # for developer's terraform refresh.
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["logs:*"]
    resources = ["*"]
  }

  # The logging module's EstimatedCharges alarm.
  statement {
    sid = "CloudWatchAlarms"
    actions = [
      "cloudwatch:DescribeAlarms",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:ListTagsForResource",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = ["*"]
  }

  # AWS-published AMI parameters (developer's al2023 lookup).
  statement {
    sid       = "SSMParameterRead"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.aws_region}::parameter/aws/service/*"]
  }

  # developer's deploy-manager.yml pushes compose updates to the manager
  # instance via SSM RunCommand and polls the invocation.
  statement {
    sid = "SSMSendCommand"
    actions = [
      "ssm:SendCommand",
      "ssm:ListCommandInvocations",
      "ssm:GetCommandInvocation",
    ]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*",
    ]
  }

  # developer's terraform refreshes two data "aws_secretsmanager_secret"
  # blocks each plan. Describe only — CI never reads secret values.
  statement {
    sid = "SecretsManagerDescribe"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:prog-strength-developer/*",
    ]
  }

  # Fleet run registry (per-SOW dispatch lock) — see
  # prog-strength-docs/sows/fleet-dispatch-gating.md. This one role does
  # double duty on this table:
  #   - control plane: developer's `terraform apply` (this role) CREATES
  #     and manages the table, and the aws provider calls several Describe*
  #     APIs on every refresh — so a data-plane-only grant fails apply with
  #     "not authorized to perform dynamodb:CreateTable".
  #   - data plane: the Dispatch SOW workflow + worker acquire / attach /
  #     release / list.
  # Granting dynamodb:* scoped to the single table ARN covers both and is
  # consistent with the ec2:*/ecr:*/s3:* resource-scoped statements above.
  statement {
    sid     = "FleetRunRegistry"
    actions = ["dynamodb:*"]
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/prog-strength-developer-runs",
    ]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.role_name}-inline"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.permissions.json
}
