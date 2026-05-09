# prog-strength-infra

Terraform configuration for the Prog Strength API host (single EC2 instance behind an
Elastic IP, in a dedicated VPC with a public subnet). State lives in S3 with native
S3 lockfile-based locking.

## Bootstrap (already done)

The S3 backend bucket and the IAM user that CI uses are provisioned manually and live
outside this repo:

- State bucket: `prog-strength-terraform-backend` (us-east-2)
- State key: `prod/terraform.tfstate`
- IAM user: credentials are wired into GitHub Actions via repo secrets.

## Required GitHub secrets

CI authenticates to AWS via the IAM user's static keys:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

## Local development

```sh
terraform init
terraform plan -var-file=environments/prod.tfvars
```

Applying locally bypasses the PR review path enforced by CI. Prefer the GitHub Actions
workflow: open a PR, review the plan, merge to apply.

## Variables

All inputs are defined in `variables.tf` with sensible defaults. The operator-facing
overrides for prod live in `environments/prod.tfvars`.

| Variable             | Default                            | Notes                                                  |
| -------------------- | ---------------------------------- | ------------------------------------------------------ |
| `aws_region`         | `us-east-2`                        |                                                        |
| `project_name`       | `prog-strength`                    | Used for tags and the `name_prefix` local.             |
| `environment`        | `prod`                             |                                                        |
| `availability_zone`  | `us-east-2b`                       | Single AZ — no multi-AZ in v1.                         |
| `vpc_cidr`           | `10.0.0.0/16`                      |                                                        |
| `public_subnet_cidr` | `10.0.1.0/24`                      |                                                        |
| `instance_type`      | `t4g.small`                        | Graviton; AMI must match `arm64`.                      |
| `ami_name_pattern`   | Ubuntu 24.04 noble arm64 (gp3)     | Filter passed to `aws_ami` data source.                |
| `ami_owner`          | `099720109477` (Canonical)         |                                                        |
| `ssh_key_name`       | `prog-strength-backend-prod-keys`  | Key pair must already exist in EC2.                    |
| `root_volume_size`   | `8`                                | GiB; gp3 encrypted root.                               |
| `ingress_rules`      | `[]`                               | Set in `environments/prod.tfvars`. SSH/80/443 by default. |

## Outputs

| Output                | Use                                                                |
| --------------------- | ------------------------------------------------------------------ |
| `instance_public_ip`  | Paste into the registrar's DNS A record for `api.progstrength.fitness`. |
| `instance_public_dns` | EIP-derived public DNS name.                                       |
| `instance_id`         | For SSM, console links, etc.                                       |
| `vpc_id`              |                                                                    |
| `public_subnet_id`    |                                                                    |
| `security_group_id`   |                                                                    |

After apply:

```sh
terraform output instance_public_ip
```
