output "bucket_name" {
  description = "S3 bucket Litestream writes replicas to. Surface this in litestream.yml on the backend host."
  value       = aws_s3_bucket.litestream.bucket
}
