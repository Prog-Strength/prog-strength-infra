# Contributing

This repo defines the AWS infrastructure for prog-strength via Terraform. Pushes to `main` automatically `terraform apply` against production (`.github/workflows/apply.yml`), so all changes flow through pull requests.

## Pull request workflow

1. Branch from `main`, make your changes, commit. The pre-commit hooks run locally — see [Local setup](#local-setup).
2. Push and open a PR. The `Terraform Plan` workflow runs:
   - `terraform fmt -check -recursive` — fails on unformatted files.
   - `terraform init`
   - `terraform validate` — fails on syntax errors, bad references, type mismatches.
   - `terraform plan -var-file=environments/prod.tfvars` — output posted as a sticky comment on the PR.
3. **Read the plan comment before merging.** Anything tagged `# forces replacement` destroys and recreates the resource. Replacing the EC2 instance wipes the SQLite DB and Caddy's Let's Encrypt cert volume — both of which then have to be rebuilt by hand. If a replacement isn't intended, fix the root cause first.
4. Merge to `main`. `Terraform Apply` runs automatically.

> [!NOTE]
> The plan workflow is only a safety net if it's required by branch protection. Configure `main` in **Settings → Branches → Branch protection rules** to require the `Terraform Plan` check to pass before merging.

## Local setup

One-time, after cloning:

```sh
brew install pre-commit terraform     # or: pipx install pre-commit
pre-commit install                    # installs the git hook
```

Terraform version should match CI (currently `1.13.0`, pinned in `.github/workflows/plan.yml` and `apply.yml`).

From then on, `git commit` runs:

- `terraform fmt` on changed `.tf` files (auto-fixes)
- `terraform validate` on touched modules (uses `-backend=false`, no AWS creds needed)
- Hygiene: trailing whitespace, EOF newline, merge conflict markers, YAML syntax, large-file guard

Run everything against the full tree without committing:

```sh
pre-commit run --all-files
```

## Code standards

- **`terraform fmt`-formatted.** CI fails on unformatted code; pre-commit auto-fixes before commit.
- **`terraform validate` clean.** Catches a class of errors before they reach `plan`.
- **Comment the *why*, not the *what*.** Reserve comments for non-obvious decisions — see the `lifecycle.ignore_changes` block in `modules/compute/main.tf` for the style. Each ignored attribute has a comment explaining *why* it's ignored, because future-you will not remember.
- **One concern per PR.** Small PRs have small plan diffs, which are reviewable. Bundling an AMI roll with a security-group edit and a new module makes the plan unreadable.

## Forcing an EC2 host replacement on purpose

The instance is pinned via `lifecycle.ignore_changes` (`modules/compute/main.tf`) so AMI publishes, bootstrap edits, and EIP-association quirks don't recycle the host. To deliberately replace it — e.g. to pick up a `bootstrap.sh` change on the live host — taint it locally and let the normal PR flow apply the change:

```sh
terraform taint module.compute.aws_instance.api
```

This marks the resource for replacement in your local state. Open a PR with whatever else you're changing (or an empty commit if there are no other changes), confirm the plan comment shows the `-/+` replacement, then merge. Apply runs and you get a fresh host.

Be aware of the side effects every time you do this: the SQLite DB at `/home/ubuntu/prog-strength-api/data/app.db` is wiped, Caddy re-requests Let's Encrypt certs (mind the rate limit — 5 duplicate certs per registered domain per week), and both the API and MCP services need to be brought back up.
