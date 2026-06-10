output "bucket_name" {
  description = "S3 bucket the backend stores user avatar uploads in. Surface this in the backend host's environment."
  value       = aws_s3_bucket.avatars.bucket
}
