variable "name_prefix" {
  description = "Prefix applied to IAM policy names so they're identifiable in the AWS console alongside the rest of the stack."
  type        = string
}

variable "instance_role_name" {
  description = "Name of the IAM role attached to the EC2 instance, owned by the compute module. This module attaches the activity photos bucket S3 access policy to it."
  type        = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name that the backend writes activity photo uploads to. Set explicitly (not generated) so the same bucket can be referenced from the API repo without a Terraform output round-trip."
  type        = string
}

variable "orphan_expiration_days" {
  description = "How long S3 retains photo objects tagged photo-status=orphaned before deleting them. Only superseded objects are tagged; current photos are untagged and never expired. Long enough to recover from a botched upload, short enough to bound storage cost."
  type        = number
  default     = 7
}

variable "cors_allowed_origins" {
  description = "Browser origins permitted to PUT directly to this bucket via presigned URL. Required since the photo upload moved off the API host: the bytes go browser->S3, so S3 itself answers the CORS preflight. Mirror the API's cors.allowed_origins — the production web origin plus the Vercel preview wildcard."
  type        = list(string)
}

variable "staged_upload_expiration_days" {
  description = "How long S3 retains objects under the uploads/ prefix before deleting them. These are staged originals with metadata (including GPS) still intact, which the worker normally deletes within seconds of processing; this is only the backstop for uploads that were never processed. Deliberately shorter than orphan_expiration_days — it is the most sensitive content in the bucket and nothing current ever lives under this prefix."
  type        = number
  default     = 1
}
