variable "aws_region" {
  description = "Region used to build resource ARNs in the role policy."
  type        = string
}

variable "github_org" {
  description = "GitHub organization the trusted repositories live under."
  type        = string
  default     = "Prog-Strength"
}

variable "main_branch_repos" {
  description = "Repositories whose Actions may assume the role from pushes to main (and workflow_dispatch runs on main)."
  type        = list(string)
  default = [
    "prog-strength-api",
    "prog-strength-agent",
    "prog-strength-mcp",
    "prog-strength-infra",
    "prog-strength-developer",
  ]
}

variable "pull_request_repos" {
  description = "Repositories whose Actions may additionally assume the role on pull_request events (terraform plan on PRs). GitHub does not issue OIDC tokens to fork PRs, so this only ever matches same-repo PRs."
  type        = list(string)
  default = [
    "prog-strength-infra",
    "prog-strength-developer",
  ]
}

variable "oidc_thumbprints" {
  description = "Thumbprint list for the GitHub OIDC provider. Must match the existing provider exactly so the import is a no-op; fetch with `aws iam get-open-id-connect-provider`."
  type        = list(string)
}

variable "role_name" {
  description = "Name of the shared CI/CD role. Stays inside the prog-strength-* IAM fence so CI can apply updates to its own policy."
  type        = string
  default     = "prog-strength-github-actions"
}
