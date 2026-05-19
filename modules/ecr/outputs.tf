output "repository_urls" {
  description = "Map of service name to full ECR repository URL (e.g. \"123456789012.dkr.ecr.us-east-2.amazonaws.com/prog-strength-prod/api\"). Used by GitHub Actions for `docker push` and by the EC2 host's docker-compose for `image:` references."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of service name to ECR repository ARN. Useful for narrowly-scoped IAM policies — granting a CI user push access to a specific repo, or the EC2 instance role pull access to specific repos rather than all of them."
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

output "registry_url" {
  description = "Registry portion of the URL (the part before the repo path). Same value for every repo in an account/region; pulled out as its own output for convenience in CI scripts that authenticate once and push to many repos."
  value = length(aws_ecr_repository.this) > 0 ? regex(
    "^([^/]+)",
    values(aws_ecr_repository.this)[0].repository_url
  )[0] : ""
}
