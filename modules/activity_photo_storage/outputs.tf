output "bucket_name" {
  description = "S3 bucket the backend stores activity photo uploads in. Surface this in the backend host's environment."
  value       = aws_s3_bucket.activity_photos.bucket
}
