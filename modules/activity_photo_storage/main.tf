# --- S3 bucket for activity photo uploads ----------------------------------
#
# The backend stores user-uploaded activity photos here. The API host (EC2
# instance) authenticates via IAM instance profile, so no access keys exist
# anywhere.
#
# Versioning is intentionally NOT enabled: each upload writes a fresh
# UUID-named object and updates the photo key on the activity row, so
# "latest wins" is correct without versioning. Reaping of superseded objects
# is handled by the lifecycle rule below, which expires ONLY objects the API
# has tagged photo-status=orphaned — never current ones.

resource "aws_s3_bucket" "activity_photos" {
  bucket = var.bucket_name

  tags = {
    Name    = var.bucket_name
    Purpose = "activity-photos"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "activity_photos" {
  bucket = aws_s3_bucket.activity_photos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access. Activity photos are never served publicly; the
# client receives time-limited presigned GET URLs minted by the API. This
# bucket is read/written exclusively by the EC2 instance role.
resource "aws_s3_bucket_public_access_block" "activity_photos" {
  bucket = aws_s3_bucket.activity_photos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "activity_photos" {
  bucket = aws_s3_bucket.activity_photos.id

  # Reap ONLY superseded ("orphaned") photo objects. On upload/delete the API
  # best-effort tags the previous object photo-status=orphaned; the current
  # photo of every activity is left UNTAGGED and therefore never matched by
  # this filter, so it is never expired. A naive age-based expiration is
  # deliberately avoided: it would delete an activity's current photo (whose
  # key still points at it) and break their image. The tag key/value here MUST
  # stay in sync with the API's TagOrphaned call (photo-status / orphaned).
  rule {
    id     = "expire-orphaned-photos"
    status = "Enabled"

    filter {
      tag {
        key   = "photo-status"
        value = "orphaned"
      }
    }

    expiration {
      days = var.orphan_expiration_days
    }
  }
}

# --- IAM: policy scoped to the activity photos bucket, attached to the EC2 role
#
# The backend uses the AWS SDK default credential chain, which picks up the
# instance role automatically when running on EC2. The role itself is owned by
# the compute module — we just author the policy here (so it stays tightly
# scoped to this bucket) and attach it.

data "aws_iam_policy_document" "activity_photos" {
  # Bucket-level: the backend lists objects to manage photo files.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.activity_photos.arn]
  }

  # Object-level: GetObject for presigned reads, PutObject for uploads,
  # PutObjectTagging to mark superseded objects orphaned for the lifecycle
  # rule, and DeleteObject as harmless future-proofing.
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.activity_photos.arn}/*"]
  }
}

resource "aws_iam_policy" "activity_photos" {
  name        = "${var.name_prefix}-activity-photos"
  description = "Read/write/tag/delete on the activity photos bucket only."
  policy      = data.aws_iam_policy_document.activity_photos.json
}

resource "aws_iam_role_policy_attachment" "activity_photos" {
  role       = var.instance_role_name
  policy_arn = aws_iam_policy.activity_photos.arn
}
