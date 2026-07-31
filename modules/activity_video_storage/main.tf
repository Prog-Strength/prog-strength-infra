# --- S3 bucket for activity video uploads ----------------------------------
#
# Mirrors activity_photo_storage, with ONE structural difference that drives
# the extra resource below: the browser writes to this bucket DIRECTLY via a
# presigned PUT, because a multi-hundred-megabyte upload cannot pass through
# the API host. That means this bucket needs a CORS policy; the photo bucket
# never did, since photo bytes flow through the API.
#
# Versioning is intentionally NOT enabled: each upload writes a fresh
# UUID-named object and the row points at that key, so "latest wins" is correct
# without versioning. Reaping is by the lifecycle rule below, which expires
# ONLY objects the API has tagged video-status=orphaned — never current ones.

resource "aws_s3_bucket" "activity_videos" {
  bucket = var.bucket_name

  tags = {
    Name    = var.bucket_name
    Purpose = "activity-videos"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "activity_videos" {
  bucket = aws_s3_bucket.activity_videos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access. Videos are never served publicly; the client gets
# time-limited presigned URLs minted by the API — presigned GET for playback
# and presigned PUT for upload. Both carry the instance role's authority in the
# signature, so public access stays fully blocked.
resource "aws_s3_bucket_public_access_block" "activity_videos" {
  bucket = aws_s3_bucket.activity_videos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- CORS: required for browser-direct upload ------------------------------
#
# NEW relative to the photo bucket, and load-bearing. The browser PUTs the
# video straight to S3 from the web app's origin, so S3 must answer the
# preflight. Without this every upload fails in the browser with an opaque CORS
# error while curl against the same presigned URL succeeds — a confusing
# failure worth naming here.
#
# ExposeHeaders includes ETag so the client can confirm what landed.
# allowed_origins carries the production origin plus the Vercel preview
# wildcard, mirroring the API's own cors.allowed_origins.
resource "aws_s3_bucket_cors_configuration" "activity_videos" {
  bucket = aws_s3_bucket.activity_videos.id

  cors_rule {
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "activity_videos" {
  bucket = aws_s3_bucket.activity_videos.id

  # Reap ONLY objects the API tagged video-status=orphaned: abandoned
  # reservations (the client never completed the upload), objects rejected at
  # commit for exceeding the size cap, and the objects behind deleted videos.
  # A current video is UNTAGGED and therefore never matched, so a naive
  # age-based expiration is deliberately avoided — it would delete videos whose
  # rows still point at them. The tag key/value MUST stay in sync with the
  # API's TagOrphaned call (video-status / orphaned) in
  # internal/activity/video_store.go.
  rule {
    id     = "expire-orphaned-videos"
    status = "Enabled"

    filter {
      tag {
        key   = "video-status"
        value = "orphaned"
      }
    }

    expiration {
      days = var.orphan_expiration_days
    }
  }

  # Abort incomplete multipart uploads. Videos are large enough that the
  # browser or SDK may use multipart, and an interrupted one leaves billable
  # parts that are invisible to a normal object listing. Photos never needed
  # this; videos do.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }
}

# --- IAM: policy scoped to the activity videos bucket, attached to the EC2 role
#
# Identical shape to the photo policy. Note there is no distinct "presign"
# permission: a presigned URL simply carries the signer's own authority, so
# PutObject here is what makes the browser's direct upload work, and GetObject
# is what makes playback URLs work.

data "aws_iam_policy_document" "activity_videos" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.activity_videos.arn]
  }

  # GetObject for presigned playback, PutObject for the browser's presigned
  # upload and the server-written poster, PutObjectTagging to mark objects
  # orphaned for the lifecycle rule, DeleteObject as future-proofing.
  # HeadObject needs no separate action — it is authorized by s3:GetObject,
  # which is what lets the commit path confirm the upload's real size.
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.activity_videos.arn}/*"]
  }

  # Cleaning up interrupted multipart uploads.
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.activity_videos.arn}/*"]
  }
}

resource "aws_iam_policy" "activity_videos" {
  name        = "${var.name_prefix}-activity-videos"
  description = "Read/write/tag/delete on the activity videos bucket only."
  policy      = data.aws_iam_policy_document.activity_videos.json
}

resource "aws_iam_role_policy_attachment" "activity_videos" {
  role       = var.instance_role_name
  policy_arn = aws_iam_policy.activity_videos.arn
}
