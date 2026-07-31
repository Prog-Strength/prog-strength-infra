output "bucket_name" {
  description = "S3 bucket activity video uploads land in. Surface this in the backend host's environment as VIDEO_BUCKET_NAME."
  value       = aws_s3_bucket.activity_videos.bucket
}
