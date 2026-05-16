output "bucket_name" {
  description = "S3 bucket Litestream writes replicas to. Surface this in litestream.yml on the API host."
  value       = aws_s3_bucket.litestream.bucket
}

output "instance_profile_name" {
  description = "Pass into the compute module's iam_instance_profile_name so the EC2 instance can authenticate to S3 without static keys."
  value       = aws_iam_instance_profile.api.name
}
