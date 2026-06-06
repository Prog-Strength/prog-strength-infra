output "bucket_name" {
  description = "S3 bucket the backend writes TCX activity file uploads to. Surface this in the backend host's environment."
  value       = aws_s3_bucket.tcx_uploads.bucket
}
