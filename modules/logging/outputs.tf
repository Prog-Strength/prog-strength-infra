output "log_group_names" {
  description = "Map of service name → log group name (e.g. api → /prog-strength/api). Useful for cross-module references and for documenting the compose-side awslogs-group values."
  value       = { for k, g in aws_cloudwatch_log_group.service : k => g.name }
}
