# --- ECR repositories for Prog Strength service images ----------------------
#
# One repository per service (api, mcp, agent). Images are pushed from
# GitHub Actions on release and pulled from the EC2 host at deploy time,
# replacing the previous "build on the host" pattern. Rollbacks become
# `docker compose pull <previous-version-tag>` rather than git checkout +
# rebuild on the host.
#
# Repository names are prefixed with the project + environment so a
# future staging environment can coexist without tag collisions
# (`prog-strength-prod/api` vs `prog-strength-staging/api`).

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name = "${var.name_prefix}/${each.key}"

  # Immutable tags prevent overwriting a published version — `v0.22.0`
  # pushed once means `v0.22.0` always pulls the same image bytes.
  # Rollback works by changing which tag docker-compose references, not
  # by re-tagging an existing tag.
  image_tag_mutability = "IMMUTABLE"

  # Native ECR vulnerability scanning. Free for basic scans; gives a
  # heads-up on CVEs in base images without wiring up a third-party
  # scanner.
  image_scanning_configuration {
    scan_on_push = true
  }

  # AWS-managed AES-256 encryption. KMS would be tighter; for a
  # single-account beta the managed key is fine and avoids the
  # per-key cost.
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.name_prefix}-${each.key}"
  }
}

# Attach the AWS-managed ECR pull policy to the EC2 instance role so
# `docker compose pull` on the host works without static credentials.
# The role itself is owned by the compute module; we just hang this
# permission off it here, keeping the ECR concern self-contained.
#
# Scoped account-wide rather than to specific repo ARNs because at
# single-account / single-environment scale the difference is
# theoretical — the only ECR repos in the account are ours. Tighten
# to an inline policy scoped to aws_ecr_repository.this[*].arn if a
# future environment ever shares this account.
resource "aws_iam_role_policy_attachment" "instance_ecr_pull" {
  role       = var.instance_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Per-repository lifecycle policy. Two rules:
#   1) Untagged images expire after a day. These appear when a build
#      pushes a new layer that's then superseded — CI noise that adds
#      storage cost without rollback value.
#   2) Tagged images are capped at the most recent N. Older versions
#      fall off so storage doesn't grow unbounded as releases pile up.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_image_expire_days} day(s)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the ${var.max_image_count} most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.max_image_count
        }
        action = { type = "expire" }
      }
    ]
  })
}
