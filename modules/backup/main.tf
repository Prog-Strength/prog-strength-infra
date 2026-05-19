# --- S3 bucket for Litestream replicas --------------------------------------
#
# Litestream streams SQLite WAL frames + periodic snapshots here. The API
# host (EC2 instance) authenticates via IAM instance profile, so no
# access keys exist anywhere.
#
# Versioning is enabled as a safety net: Litestream can be told to delete
# old generations, and an accidental `aws s3 rm` would otherwise be
# irreversible. The lifecycle rule keeps storage cost bounded by expiring
# noncurrent versions after a configurable window.

resource "aws_s3_bucket" "litestream" {
  bucket = var.bucket_name

  tags = {
    Name    = var.bucket_name
    Purpose = "litestream-replicas"
  }
}

resource "aws_s3_bucket_versioning" "litestream" {
  bucket = aws_s3_bucket.litestream.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "litestream" {
  bucket = aws_s3_bucket.litestream.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access. Litestream replicas are never served publicly;
# this bucket is read/written exclusively by the EC2 instance role.
resource "aws_s3_bucket_public_access_block" "litestream" {
  bucket = aws_s3_bucket.litestream.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "litestream" {
  bucket = aws_s3_bucket.litestream.id

  # Lifecycle requires versioning to be settled first; otherwise apply
  # races between "enable versioning" and "configure lifecycle for
  # noncurrent versions" can fail with a transient state error.
  depends_on = [aws_s3_bucket_versioning.litestream]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # Required in AWS provider v6 even when applying to all objects.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

# --- IAM: policy scoped to the Litestream bucket, attached to the EC2 role --
#
# Litestream's S3 backend uses the AWS SDK default credential chain, which
# picks up the instance role automatically when running on EC2. The role
# itself is owned by the compute module — we just author the policy here
# (so it stays tightly scoped to this bucket) and attach it.

data "aws_iam_policy_document" "litestream" {
  # Bucket-level: Litestream lists generations to decide what to write/restore.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.litestream.arn]
  }

  # Object-level: read, write, and prune (delete) generations under any key.
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.litestream.arn}/*"]
  }
}

resource "aws_iam_policy" "litestream" {
  name        = "${var.name_prefix}-litestream"
  description = "Read/write/delete on the Litestream replica bucket only."
  policy      = data.aws_iam_policy_document.litestream.json
}

resource "aws_iam_role_policy_attachment" "litestream" {
  role       = var.instance_role_name
  policy_arn = aws_iam_policy.litestream.arn
}
