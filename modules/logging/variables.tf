variable "name_prefix" {
  description = "Prefix applied to IAM policy + alarm names so they sit next to the rest of the stack in the AWS console."
  type        = string
}

variable "instance_role_name" {
  description = "Name of the IAM role attached to the EC2 instance, owned by the compute module. This module attaches a CloudWatch Logs write policy to it scoped to the three Prog Strength log groups."
  type        = string
}

variable "service_names" {
  description = "Logical names of the docker-compose services that will ship logs. Each becomes one log group named /prog-strength/<name>. Default covers the current api/agent/mcp trio; adding a service is a one-element change here, not a refactor."
  type        = list(string)
  default     = ["api", "agent", "mcp"]
}

variable "retention_days" {
  description = "How long CloudWatch retains log events before automatic deletion. Default 30 — long enough for week-old investigations, short enough that storage stays under a dollar/month."
  type        = number
  default     = 30
}

variable "monthly_budget_usd" {
  description = "Threshold for the EstimatedCharges alarm. Fires when the AWS bill crosses this number, scoped to the CloudWatch service so unrelated charges don't trip it. Set to 0 to skip creating the alarm entirely (useful for local/dev plans that don't want spurious noise)."
  type        = number
  default     = 5
}
