variable "name_prefix" {
  description = "Prefix applied to IAM policy names so they're identifiable in the AWS console alongside the rest of the stack."
  type        = string
}

variable "instance_role_name" {
  description = "Name of the IAM role attached to the EC2 instance, owned by the compute module. This module attaches the activity videos bucket S3 access policy to it."
  type        = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name that activity video uploads land in. Set explicitly (not generated) so the same bucket can be referenced from the API repo without a Terraform output round-trip."
  type        = string
}

variable "cors_allowed_origins" {
  description = "Browser origins permitted to PUT directly to this bucket via presigned URL. Required — unlike photos, video bytes go browser→S3, so S3 itself answers the CORS preflight. Mirror the API's cors.allowed_origins: the production web origin plus the Vercel preview wildcard."
  type        = list(string)
}

variable "orphan_expiration_days" {
  description = "How long S3 retains video objects tagged video-status=orphaned before deleting them. Only abandoned, rejected, or deleted videos are tagged; current videos are untagged and never expired."
  type        = number
  default     = 7
}

variable "abort_incomplete_multipart_days" {
  description = "How long S3 keeps the parts of an interrupted multipart upload before aborting it. Videos are large enough that clients may use multipart, and orphaned parts are billable but invisible to a normal object listing."
  type        = number
  default     = 3
}
