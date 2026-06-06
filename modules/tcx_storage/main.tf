# --- S3 bucket for TCX activity file uploads --------------------------------
#
# The backend stores uploaded TCX activity files here. The API host (EC2
# instance) authenticates via IAM instance profile, so no access keys exist
# anywhere.
#
# Versioning is enabled as a safety net: an accidental `aws s3 rm` would
# otherwise be irreversible. The lifecycle rule keeps storage cost bounded by
# expiring noncurrent versions after a configurable window.

resource "aws_s3_bucket" "tcx_uploads" {
  bucket = var.bucket_name

  tags = {
    Name    = var.bucket_name
    Purpose = "tcx-uploads"
  }
}

resource "aws_s3_bucket_versioning" "tcx_uploads" {
  bucket = aws_s3_bucket.tcx_uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tcx_uploads" {
  bucket = aws_s3_bucket.tcx_uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access. TCX uploads are never served publicly;
# this bucket is read/written exclusively by the EC2 instance role.
resource "aws_s3_bucket_public_access_block" "tcx_uploads" {
  bucket = aws_s3_bucket.tcx_uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tcx_uploads" {
  bucket = aws_s3_bucket.tcx_uploads.id

  # Lifecycle requires versioning to be settled first; otherwise apply
  # races between "enable versioning" and "configure lifecycle for
  # noncurrent versions" can fail with a transient state error.
  depends_on = [aws_s3_bucket_versioning.tcx_uploads]

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

# --- IAM: policy scoped to the TCX uploads bucket, attached to the EC2 role --
#
# The backend uses the AWS SDK default credential chain, which picks up the
# instance role automatically when running on EC2. The role itself is owned by
# the compute module — we just author the policy here (so it stays tightly
# scoped to this bucket) and attach it.

data "aws_iam_policy_document" "tcx_uploads" {
  # Bucket-level: the backend lists objects to manage uploaded activity files.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tcx_uploads.arn]
  }

  # Object-level: read, write, and delete TCX files under any key.
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.tcx_uploads.arn}/*"]
  }
}

resource "aws_iam_policy" "tcx_uploads" {
  name        = "${var.name_prefix}-tcx"
  description = "Read/write/delete on the TCX uploads bucket only."
  policy      = data.aws_iam_policy_document.tcx_uploads.json
}

resource "aws_iam_role_policy_attachment" "tcx_uploads" {
  role       = var.instance_role_name
  policy_arn = aws_iam_policy.tcx_uploads.arn
}
