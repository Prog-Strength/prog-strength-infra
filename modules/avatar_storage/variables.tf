variable "name_prefix" {
  description = "Prefix applied to IAM policy names so they're identifiable in the AWS console alongside the rest of the stack."
  type        = string
}

variable "instance_role_name" {
  description = "Name of the IAM role attached to the EC2 instance, owned by the compute module. This module attaches the avatar bucket S3 access policy to it."
  type        = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name that the backend writes user avatar uploads to. Set explicitly (not generated) so the same bucket can be referenced from the API repo without a Terraform output round-trip."
  type        = string
}

variable "orphan_expiration_days" {
  description = "How long S3 retains avatar objects tagged avatar-status=orphaned before deleting them. Only superseded objects are tagged; current avatars are untagged and never expired. Long enough to recover from a botched upload, short enough to bound storage cost."
  type        = number
  default     = 7
}
