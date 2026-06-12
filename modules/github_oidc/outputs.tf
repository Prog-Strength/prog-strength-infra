output "role_arn" {
  description = "ARN of the shared CI/CD role. Set as the org-level AWS_GHA_ROLE_ARN secret on GitHub."
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "ARN of the (imported) GitHub OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}
