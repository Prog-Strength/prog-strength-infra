variable "name_prefix" {
  description = "Prefix applied to IAM policy names so they're identifiable in the AWS console alongside the rest of the stack."
  type        = string
}

variable "instance_role_name" {
  description = "Name of the IAM role attached to the EC2 instance, owned by the compute module. This module attaches the Litestream S3 access policy to it."
  type        = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name that Litestream writes SQLite WAL frames and snapshots to. Set explicitly (not generated) so the same bucket can be referenced from the API repo's litestream.yml without a Terraform output round-trip."
  type        = string
}

variable "noncurrent_version_expiration_days" {
  description = "How long S3 retains noncurrent object versions before permanent deletion. Belt-and-suspenders alongside Litestream's own retention — versioning catches accidental deletes; this lifecycle rule prevents the bucket from growing forever."
  type        = number
  default     = 30
}
