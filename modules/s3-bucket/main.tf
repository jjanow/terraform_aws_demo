data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project}-${var.environment}-${var.bucket_name_suffix}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Bucket ─────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = local.tags
}

# ── Versioning ─────────────────────────────────────────────────────────────────

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

# ── Encryption (non-overrideable) ──────────────────────────────────────────────

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── Public access block (non-overrideable) ─────────────────────────────────────
#
# When enable_website = true, block_public_policy and restrict_public_buckets
# are relaxed so a public bucket policy can be attached for CloudFront or direct
# static-site delivery. block_public_acls and ignore_public_acls remain true
# because ACL-based public access is legacy and unnecessary for website hosting.
#
# IMPORTANT: the account-level public access block is NOT managed here to avoid
# conflicts across modules. Ensure aws_s3_account_public_access_block is managed
# at the account level — see the README security section.

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = var.enable_website ? false : true
  restrict_public_buckets = var.enable_website ? false : true
}

# ── Access logging (optional) ──────────────────────────────────────────────────

resource "aws_s3_bucket_logging" "this" {
  count = var.log_bucket_id != null ? 1 : 0

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.log_bucket_id
  target_prefix = "${local.bucket_name}/"
}

# ── Static website hosting (optional) ─────────────────────────────────────────

resource "aws_s3_bucket_website_configuration" "this" {
  count = var.enable_website ? 1 : 0

  bucket = aws_s3_bucket.this.id

  index_document {
    suffix = var.website_index_document
  }
}

# ── CORS (optional) ────────────────────────────────────────────────────────────

resource "aws_s3_bucket_cors_configuration" "this" {
  count = length(var.cors_allowed_origins) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this.id

  cors_rule {
    allowed_origins = var.cors_allowed_origins
    allowed_methods = ["GET", "HEAD"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}
