# prog-strength-infra

Terraform configuration for the Prog Strength backend host (single EC2 instance behind an
Elastic IP, in a dedicated VPC with a public subnet). State lives in S3 with native
S3 lockfile-based locking.

## Bootstrap (already done)

The S3 backend bucket is provisioned manually and lives outside this repo:

- State bucket: `prog-strength-terraform-backend` (us-east-2)
- State key: `prod/terraform.tfstate`

CI no longer uses a static IAM user. Workflows authenticate to AWS by assuming
the shared GitHub Actions OIDC role, which this repo manages in
`modules/github_oidc`. The OIDC provider itself predates the module and is
imported (see `imports.tf`).

## Required GitHub secrets

CI authenticates to AWS via short-lived credentials from the OIDC role — no
static keys:

- `AWS_GHA_ROLE_ARN` — ARN of the shared CI/CD role assumed by
  `configure-aws-credentials` in `plan.yml`, `apply.yml`, and
  `replace-instance.yml`.

The Caddy deploy workflow (`deploy-caddy.yml`) deploys via SSM Run Command
using the same OIDC role — no SSH, no inbound port 22, and no `EC2_HOST` /
`EC2_SSH_KEY` secrets. It targets the host by its `Name` tag, so it also
survives an instance replacement.

## Local development

```sh
terraform init
terraform plan -var-file=environments/prod.tfvars
```

Applying locally bypasses the PR review path enforced by CI. Prefer the GitHub Actions
workflow: open a PR, review the plan, merge to apply.

## Variables

Inputs are grouped into object-typed variables in `variables.tf`, one per concern
(`project`, `aws`, `network`, `compute`, `backup`, `tcx_storage`, `avatar_storage`,
`ecr`, `logging`, `github_oidc`). Each maps to a module in `modules/` except
`project`/`aws`/`network`, which feed the root and the `network` module. The
operator-facing overrides for prod live in `environments/prod.tfvars`.

### `project`

| Field         | Default         | Notes                                          |
| ------------- | --------------- | ---------------------------------------------- |
| `name`        | `prog-strength` | Used for tags and the `name_prefix` local.     |
| `environment` | `prod`          |                                                |

### `aws`

| Field               | Default      | Notes                            |
| ------------------- | ------------ | -------------------------------- |
| `region`            | `us-east-2`  |                                  |
| `availability_zone` | `us-east-2b` | Single AZ — no multi-AZ in v1.   |

### `network`

| Field                | Default       |
| -------------------- | ------------- |
| `vpc_cidr`           | `10.0.0.0/16` |
| `public_subnet_cidr` | `10.0.1.0/24` |

### `compute`

| Field                            | Default                           | Notes                                                     |
| -------------------------------- | --------------------------------- | --------------------------------------------------------- |
| `instance_type`                  | `t4g.small`                       | Graviton; AMI must match `arm64`.                         |
| `ami_name_pattern`               | Ubuntu 24.04 noble arm64 (gp3)    | Filter passed to `aws_ami` data source.                   |
| `ami_owner`                      | `099720109477` (Canonical)        |                                                           |
| `ssh_key_name`                   | `prog-strength-backend-prod-keys` | Key pair must already exist in EC2. Unused now that port 22 is closed — deploys + break-glass go through SSM. |
| `root_volume_size`               | `8`                               | GiB; gp3 encrypted root.                                  |
| `security_group.ingress_rules`   | `[]`                              | Set in `environments/prod.tfvars`. 80/443 by default (no inbound SSH — deploys + break-glass go through SSM). |
| `bootstrap.infra_repo_url`       | This repo's HTTPS clone URL        | Cloned by `bootstrap.sh` on first boot for the host's compose manifests. |

The instance also gets a single IAM instance profile (produced by the
`compute` module) to which the `backup`, `tcx_storage`, `avatar_storage`,
`ecr`, and `logging` modules attach their scoped policies — see `main.tf`.
That lets on-host services (Litestream, the API, the deploy workflows'
ECR login, the CloudWatch log driver) call AWS without static keys.

### `backup`

Litestream replica bucket + IAM role/policy. Owned by `modules/backup/`.

| Field                                | Default                            | Notes                                                                |
| ------------------------------------ | ---------------------------------- | -------------------------------------------------------------------- |
| `bucket_name`                        | `prog-strength-database-backups`   | Globally-unique S3 name. Referenced from the backend host's `.env`.  |
| `noncurrent_version_expiration_days` | `30`                               | Lifecycle rule on the versioned bucket; bounds storage cost.         |

The bucket is private (public access fully blocked), versioned, and
SSE-S3 encrypted. The associated IAM policy grants `s3:Get/Put/Delete/List`
on this bucket only and is attached to the backend instance's role.

### `tcx_storage`

Garmin TCX activity-file uploads bucket. Owned by `modules/tcx_storage/`.
Same private/versioned/SSE-S3 shape as `backup`; the scoped policy is
attached to the backend instance role.

| Field                                | Default                     | Notes                                  |
| ------------------------------------ | --------------------------- | -------------------------------------- |
| `bucket_name`                        | `prog-strength-tcx-uploads` | Globally-unique S3 name.               |
| `noncurrent_version_expiration_days` | `30`                        | Lifecycle rule bounds storage cost.    |

### `avatar_storage`

User avatar image uploads bucket. Owned by `modules/avatar_storage/`.

| Field                    | Default               | Notes                                                              |
| ------------------------ | --------------------- | ------------------------------------------------------------------ |
| `bucket_name`            | `prog-strength-avatars` | Globally-unique S3 name.                                         |
| `orphan_expiration_days` | `7`                   | Reaps objects **tagged** `avatar-status=orphaned` — not age-based. |

### `ecr`

Container registries the GitHub Actions builds push to and the host pulls
from at deploy time. Owned by `modules/ecr/`.

| Field                        | Default                | Notes                                          |
| ---------------------------- | ---------------------- | ---------------------------------------------- |
| `repository_names`           | `["api","mcp","agent"]` | One repo per service so lifecycle/tag rules scope per image. |
| `max_image_count`            | `10`                   | Lifecycle: keep the N most recent tagged images. |
| `untagged_image_expire_days` | `1`                    | Lifecycle: expire untagged images quickly.     |

### `logging`

CloudWatch Logs for the docker-compose service containers. Owned by
`modules/logging/`.

| Field                | Default                  | Notes                                                            |
| -------------------- | ------------------------ | ---------------------------------------------------------------- |
| `service_names`      | `["api","agent","mcp"]`  | One log group each: `/prog-strength/<name>`.                     |
| `retention_days`     | `30`                     | Bounds storage cost.                                             |
| `monthly_budget_usd` | `5`                      | `EstimatedCharges` alarm threshold; `0` skips the alarm.         |

### `github_oidc`

The shared GitHub Actions OIDC CI/CD role used by every Prog Strength repo's
workflows. Owned by `modules/github_oidc/`. The OIDC provider is imported
(`imports.tf`), so `oidc_thumbprints` must match the existing provider — fetch
with `aws iam get-open-id-connect-provider`.

| Field              | Default     | Notes                                            |
| ------------------ | ----------- | ------------------------------------------------ |
| `oidc_thumbprints` | _(required)_ | Must match the imported provider's thumbprints. |

## Outputs

| Output                        | Use                                                                     |
| ----------------------------- | ----------------------------------------------------------------------- |
| `instance_public_ip`          | Paste into the registrar's DNS A record for `api.progstrength.fitness`. |
| `instance_public_dns`         | EIP-derived public DNS name.                                            |
| `instance_id`                 | For SSM, console links, etc.                                            |
| `vpc_id`                      |                                                                         |
| `public_subnet_id`            |                                                                         |
| `security_group_id`           |                                                                         |
| `litestream_bucket_name`      | Set as `LITESTREAM_REPLICA_BUCKET` in the backend host's `.env`.        |
| `api_instance_profile_name`   | Visibility only — already wired into `aws_instance.backend`.                |

After apply:

```sh
terraform output instance_public_ip
```
