# Prog Strength Infra — Agent Contributor Guide

This file is for AI coding agents (Claude, Copilot, Codex, Gemini, etc.)
making contributions to `prog-strength-infra`. Human contributors should
start with [CONTRIBUTING.md](CONTRIBUTING.md) and [README.md](README.md) —
this file does not duplicate the variable/output reference or the PR
mechanics; it's the project-shaped context that takes longest to recover
from the `.tf` files alone: what this stack is, what's deliberately small,
and which moves are dangerous.

## What this project is

The Terraform for the Prog Strength **application** stack: one EC2 host
that runs the entire backend, plus the AWS resources around it. There is
no Kubernetes, no autoscaling group, no load balancer, no RDS. The host is
a single `t4g.small` (Graviton/arm64) Ubuntu instance behind an Elastic IP,
in a dedicated VPC with one public subnet. State lives in S3
(`prog-strength-terraform-backend`, us-east-2) with native S3 lockfile
locking.

Everything the backend needs runs as Docker Compose stacks **on that one
host**: the Go API, the MCP server, the agent, Caddy (TLS termination +
reverse proxy), and the Prometheus/Grafana monitoring stack. This repo
owns the orchestration manifests for them — `compose/`, `caddy/`,
`monitoring/` — which the host clones on first boot (`bootstrap.sh`) and
the deploy workflows `git pull` thereafter. The service **images** are
built and pushed to ECR by each service repo's own CI; this repo only
provides the host, the registries, and the manifests.

Do not confuse this with **`prog-strength-developer`**, which is also
Terraform but provisions a completely separate, ephemeral stack (the
autonomous-developer EC2 workers). Changes here never touch that.

This is a solo portfolio project. The infrastructure is deliberately
minimal and cost-conscious — a single small instance, tight CloudWatch
retention, lifecycle rules that reap old objects. Prefer the cheap,
simple option and call out cost before proposing anything that scales
spend.

## Working on this repo as an agent

- **Run the checks locally before opening a PR.** `pre-commit install`
  arms both stages; `git commit` runs fmt + shellcheck + hygiene, `git
  push` runs `terraform validate` + `tflint`. CI re-runs these as the
  `Lint` and `Terraform Plan` status checks — a PR whose checks you never
  ran locally is a CI round-trip someone else pays for. See
  [CONTRIBUTING.md → Local setup](CONTRIBUTING.md#local-setup).
- **Plan on PR, apply on merge.** Pushes to `main` `terraform apply`
  against production automatically (`apply.yml`). There is no manual
  approval gate beyond the PR review, so every change flows through a PR
  and you **read the plan comment before merging**.
- **Treat `# forces replacement` as a stop sign.** Anything that recreates
  `aws_instance.backend` is destructive — see [The danger zone](#the-danger-zone)
  below. If a plan shows an unintended replacement, fix the root cause;
  don't merge through it.
- **No static AWS keys.** CI assumes the shared GitHub Actions OIDC role
  (`modules/github_oidc`); on-host services use the instance profile. If a
  change seems to need an access key, that's a smell — surface it instead
  of adding one.
- **One concern per PR.** Small PRs have small, reviewable plan diffs.
  Bundling an AMI roll with a security-group edit and a new module makes
  the plan unreadable — which defeats the only review gate this repo has.
- **Comment the *why*, not the *what*.** Match the existing density: the
  `lifecycle.ignore_changes` block in `modules/compute/main.tf` documents
  why each attribute is ignored. No emoji, no decorative ASCII.
- **Never commit secrets.** `.env` is gitignored and stays that way. Don't
  read operator credentials into context or echo them into `.tf`/tfvars.
- **Surface bypasses.** Reaching for `--no-verify`, a broadened
  `shellcheck disable`, or a `tflint` ignore is a red flag — explain why
  in the PR rather than hiding it.

## Repo layout

The root module wires per-concern modules together (`main.tf`), each
driven by one object-typed variable (`variables.tf`). Operator overrides
for prod live in `environments/prod.tfvars`.

| Module                   | What it provisions                                                            |
| ------------------------ | ----------------------------------------------------------------------------- |
| `network`                | VPC, public subnet, IGW, route table.                                         |
| `security_group`         | The instance's security group (SSH / 80 / 443).                               |
| `compute`                | The EC2 host, its EIP, the instance IAM role/profile, and `bootstrap.sh`.     |
| `backup`                 | Litestream S3 replica bucket (SQLite WAL + snapshots) and its scoped policy.  |
| `tcx_storage`            | S3 bucket for Garmin TCX activity-file uploads.                               |
| `avatar_storage`         | S3 bucket for user avatar images (tag-based orphan reaping).                  |
| `ecr`                    | One ECR repo per service (`api`, `mcp`, `agent`) + lifecycle policies.        |
| `logging`                | CloudWatch log groups per service + an `EstimatedCharges` budget alarm.       |
| `github_oidc`            | The **shared** CI/CD OIDC role used by every Prog Strength repo's workflows.  |

The `backup`/`tcx_storage`/`avatar_storage`/`ecr`/`logging` modules each
attach a scoped policy to the **single** instance role the `compute`
module creates, so the host authenticates to every AWS service it touches
without keys. Non-Terraform directories: `compose/` (per-service
docker-compose manifests), `caddy/` (the `Caddyfile`), `monitoring/`
(Prometheus/Grafana config). `imports.tf` holds resources adopted into
state rather than created (e.g. the pre-existing OIDC provider).

## CI/CD

| Workflow                  | Trigger                          | Does                                                                 |
| ------------------------- | -------------------------------- | ------------------------------------------------------------------- |
| `lint.yml`                | PR → main                        | `tflint --recursive` + `shellcheck`. No AWS access; fast feedback.  |
| `plan.yml`                | PR → main                        | fmt-check, init, validate, then `terraform plan` as a sticky comment. |
| `apply.yml`               | push → main (and manual)         | `terraform apply -auto-approve` against prod.                       |
| `deploy-caddy.yml`        | push → main touching `caddy/**`  | SSHes in and reloads Caddy in place (keeps issued LE certs).        |
| `replace-instance.yml`    | manual, typed `REPLACE` gate     | Deliberately replaces the EC2 host. See below.                      |

## The danger zone

The EC2 instance is pinned via `lifecycle.ignore_changes`
(`modules/compute/main.tf`) precisely because replacing it is expensive.
Replacing the host:

- **Wipes the SQLite DB** at the host's `compose/api/data/app.db` — it (and
  `telemetry.db`) only come back if Litestream has a replica to restore
  from, via the restore sidecars in `compose/api`.
- **Forces Caddy to re-request Let's Encrypt certs.** Mind the rate limit:
  5 duplicate certs per registered domain per week. Burn through it and
  the site has no TLS until it resets.
- **Resets the root EBS volume** — Grafana's SQLite state and the
  Prometheus TSDB are gone.

So: never let a plan recreate `aws_instance.backend` as a side effect. When
a replacement is genuinely intended (e.g. to pick up a `bootstrap.sh`
change on the live host), do it deliberately — `terraform taint` locally
or the `replace-instance.yml` workflow — and confirm the plan's `-/+`
before pulling the trigger. The full procedure and side-effect checklist
is in [CONTRIBUTING.md → Forcing an EC2 host replacement](CONTRIBUTING.md#forcing-an-ec2-host-replacement-on-purpose).

## Deliberately deferred

Out of scope by design — do not add without asking:

- **Multi-AZ / multi-instance / autoscaling.** Single host, single AZ is
  the intended shape. The data layer is local SQLite + Litestream, which
  does not fan out across instances.
- **Managed databases (RDS/Aurora), load balancers, CDNs.** The product is
  single-user; none of these are warranted yet.
- **A staging environment.** There is one environment (`prod`). If multi-env
  becomes real, it's a design conversation, not a drive-by `count`/workspace
  change.
- **Secrets managers / Vault for app config.** App secrets live in the
  host's gitignored `.env`. Don't introduce a secrets backend without a
  reason that's been agreed.
