variable "env" {
  description = "Environment segment in the secret name (e.g. prod). Encoded up front so a future environment is prog-strength-backend/staging/* with no rename of the prod secrets."
  type        = string
}

variable "services" {
  description = "Map of backend service name => the secret container's self-documenting description. Drives one aws_secretsmanager_secret per service via for_each, so a new service or environment is a one-line addition."
  type        = map(string)
}

variable "instance_role_name" {
  description = "Name of the EC2 instance IAM role to grant GetSecretValue on this environment's backend secrets. Mirrors the additive-attachment pattern used by the ecr/backup modules."
  type        = string
}
