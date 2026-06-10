# --- S3 bucket for user avatar uploads -------------------------------------
#
# The backend stores user-uploaded avatar images here. The API host (EC2
# instance) authenticates via IAM instance profile, so no access keys exist
# anywhere.
#
# Versioning is intentionally NOT enabled: each upload writes a fresh
# UUID-named object (user_id=<id>/<uuid>.<ext>) and updates avatar_key on the
# user row, so "latest wins" is correct without versioning. Reaping of
# superseded objects is handled by the lifecycle rule below, which expires
# ONLY objects the API has tagged avatar-status=orphaned — never current ones.

resource "aws_s3_bucket" "avatars" {
  bucket = var.bucket_name

  tags = {
    Name    = var.bucket_name
    Purpose = "user-avatars"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "avatars" {
  bucket = aws_s3_bucket.avatars.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access. Avatars are never served publicly; the client
# receives time-limited presigned GET URLs minted by the API. This bucket is
# read/written exclusively by the EC2 instance role.
resource "aws_s3_bucket_public_access_block" "avatars" {
  bucket = aws_s3_bucket.avatars.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "avatars" {
  bucket = aws_s3_bucket.avatars.id

  # Reap ONLY superseded ("orphaned") avatar objects. On upload/delete the API
  # best-effort tags the previous object avatar-status=orphaned; the current
  # avatar of every user is left UNTAGGED and therefore never matched by this
  # filter, so it is never expired. A naive age-based expiration is deliberately
  # avoided: it would delete a user's current avatar (whose avatar_key still
  # points at it) and break their image. The tag key/value here MUST stay in
  # sync with the API's TagOrphaned call (avatar-status / orphaned).
  rule {
    id     = "expire-orphaned-avatars"
    status = "Enabled"

    filter {
      tag {
        key   = "avatar-status"
        value = "orphaned"
      }
    }

    expiration {
      days = var.orphan_expiration_days
    }
  }
}

# --- IAM: policy scoped to the avatars bucket, attached to the EC2 role ------
#
# The backend uses the AWS SDK default credential chain, which picks up the
# instance role automatically when running on EC2. The role itself is owned by
# the compute module — we just author the policy here (so it stays tightly
# scoped to this bucket) and attach it.

data "aws_iam_policy_document" "avatars" {
  # Bucket-level: the backend lists objects to manage avatar files.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.avatars.arn]
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
    resources = ["${aws_s3_bucket.avatars.arn}/*"]
  }
}

resource "aws_iam_policy" "avatars" {
  name        = "${var.name_prefix}-avatars"
  description = "Read/write/tag/delete on the user avatars bucket only."
  policy      = data.aws_iam_policy_document.avatars.json
}

resource "aws_iam_role_policy_attachment" "avatars" {
  role       = var.instance_role_name
  policy_arn = aws_iam_policy.avatars.arn
}
