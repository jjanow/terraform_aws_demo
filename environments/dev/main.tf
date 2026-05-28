data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix    = "${local.project}-${local.environment}"
  api_name       = "${local.name_prefix}-api"
  api_stage_name = "v1"
  lambda_timeout = 30
}

# ── S3 — Log bucket (frontend access logs) ────────────────────────────────────

module "log_bucket" {
  source = "../../modules/s3-bucket"

  bucket_name_suffix = "logs"
  environment        = local.environment
  project            = local.project
  enable_versioning  = false
  enable_website     = false
}

# ── S3 — State log bucket (infrastructure / CloudTrail access logs) ───────────

module "state_log_bucket" {
  source = "../../modules/s3-bucket"

  bucket_name_suffix = "state-logs"
  environment        = local.environment
  project            = local.project
  enable_versioning  = false
  enable_website     = false
}

# ── S3 — Frontend bucket ──────────────────────────────────────────────────────

module "frontend_bucket" {
  source = "../../modules/s3-bucket"

  bucket_name_suffix = "frontend"
  environment        = local.environment
  project            = local.project
  enable_website     = true
  log_bucket_id      = module.log_bucket.bucket_id
}

# ── DynamoDB — URLs table ─────────────────────────────────────────────────────

module "urls_table" {
  source = "../../modules/dynamodb-table"

  table_name    = "${local.name_prefix}-urls"
  hash_key      = "short_code"
  ttl_attribute = "expires_at"
  environment   = local.environment
  project       = local.project

  global_secondary_indexes = [
    {
      name            = "by_owner"
      hash_key        = "owner_id"
      projection_type = "ALL"
    },
  ]
}

# ── DynamoDB — Analytics table ────────────────────────────────────────────────

module "analytics_table" {
  source = "../../modules/dynamodb-table"

  table_name    = "${local.name_prefix}-analytics"
  hash_key      = "short_code"
  range_key     = "timestamp"
  ttl_attribute = "ttl"
  environment   = local.environment
  project       = local.project
}

# ── SQS — Click event queues ──────────────────────────────────────────────────

resource "aws_sqs_queue" "click_dlq" {
  name                      = "${local.name_prefix}-click-events-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "click_events" {
  name                       = "${local.name_prefix}-click-events"
  visibility_timeout_seconds = local.lambda_timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.click_dlq.arn
    maxReceiveCount     = 3
  })
}

# ── API Gateway ───────────────────────────────────────────────────────────────
# Declared before CloudFront so module.api.api_id (aws_api_gateway_rest_api.this.id)
# is usable as the CF origin domain. api_id has no dependency on the Lambda
# functions, so using it breaks the would-be cycle:
#   CF → API stage → integrations → Lambda → CF (env var DOMAIN_NAME).

module "api" {
  source = "../../modules/api-gateway"

  api_name    = local.api_name
  description = "URL shortener REST API"
  stage_name  = local.api_stage_name
  burst_limit = 100
  rate_limit  = 50
  environment = local.environment
  project     = local.project

  lambda_integrations = [
    {
      http_method          = "POST"
      resource_path        = "/api/shorten"
      lambda_invoke_arn    = module.shorten_function.invoke_arn
      lambda_function_name = module.shorten_function.function_name
    },
    {
      http_method          = "GET"
      resource_path        = "/api/{short_code}"
      lambda_invoke_arn    = module.redirect_function.invoke_arn
      lambda_function_name = module.redirect_function.function_name
    },
  ]
}

# ── CloudFront ────────────────────────────────────────────────────────────────

locals {
  # Constructed from api_id (REST API only) — avoids pulling in the stage/
  # deployment dependency chain and the Lambda functions that depend on CF.
  api_origin_domain = "${module.api.api_id}.execute-api.${data.aws_region.current.name}.amazonaws.com"
}

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name_prefix}-s3-oac"
  description                       = "OAC for ${local.name_prefix} frontend bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${local.name_prefix} distribution"

  origin {
    domain_name              = module.frontend_bucket.bucket_regional_domain_name
    origin_id                = "S3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    domain_name = local.api_origin_domain
    origin_id   = "APIGW"
    origin_path = "/${local.api_stage_name}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "APIGW"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Accept", "Content-Type"]
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_policy" "frontend_cf" {
  bucket = module.frontend_bucket.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${module.frontend_bucket.bucket_arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
          }
        }
      },
    ]
  })
}

# ── Lambda — Shorten ──────────────────────────────────────────────────────────

module "shorten_function" {
  source = "../../modules/lambda-function"

  function_name      = "${local.name_prefix}-shorten"
  description        = "Shortens a long URL and stores it in DynamoDB"
  handler            = "index.handler"
  source_dir         = "${path.module}/../../src/functions/shorten"
  timeout            = local.lambda_timeout
  log_retention_days = 14
  environment        = local.environment
  project            = local.project

  environment_variables = {
    URLS_TABLE_NAME = module.urls_table.table_name
    SQS_QUEUE_URL   = aws_sqs_queue.click_events.url
    DOMAIN_NAME     = aws_cloudfront_distribution.this.domain_name
  }

  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBUrls"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
        ]
        Resource = module.urls_table.table_arn
      },
      {
        Sid      = "SQSSend"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.click_events.arn
      },
    ]
  })
}

# ── Lambda — Redirect ─────────────────────────────────────────────────────────

module "redirect_function" {
  source = "../../modules/lambda-function"

  function_name      = "${local.name_prefix}-redirect"
  description        = "Looks up a short code and returns a 301 redirect"
  handler            = "index.handler"
  source_dir         = "${path.module}/../../src/functions/redirect"
  timeout            = local.lambda_timeout
  log_retention_days = 14
  environment        = local.environment
  project            = local.project

  environment_variables = {
    URLS_TABLE_NAME = module.urls_table.table_name
    SQS_QUEUE_URL   = aws_sqs_queue.click_events.url
  }

  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DynamoDBUrls"
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = module.urls_table.table_arn
      },
      {
        Sid      = "SQSSend"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.click_events.arn
      },
    ]
  })
}

# ── Lambda — Analytics ────────────────────────────────────────────────────────

module "analytics_function" {
  source = "../../modules/lambda-function"

  function_name      = "${local.name_prefix}-analytics"
  description        = "Processes click events from SQS and writes to DynamoDB"
  handler            = "index.handler"
  source_dir         = "${path.module}/../../src/functions/analytics"
  timeout            = local.lambda_timeout
  log_retention_days = 14
  environment        = local.environment
  project            = local.project

  environment_variables = {
    ANALYTICS_TABLE_NAME = module.analytics_table.table_name
  }

  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DynamoDBAnalytics"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = module.analytics_table.table_arn
      },
      {
        Sid    = "SQSConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.click_events.arn
      },
    ]
  })
}

# ── Lambda event source mapping ───────────────────────────────────────────────

resource "aws_lambda_event_source_mapping" "analytics_sqs" {
  event_source_arn        = aws_sqs_queue.click_events.arn
  function_name           = module.analytics_function.function_arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}

# ── CloudWatch monitoring ──────────────────────────────────────────────────────

module "monitoring" {
  source = "../../modules/cloudwatch-monitoring"

  function_names = [
    module.shorten_function.function_name,
    module.redirect_function.function_name,
    module.analytics_function.function_name,
  ]
  api_gateway_name = local.api_name
  dynamodb_table_names = [
    module.urls_table.table_name,
    module.analytics_table.table_name,
  ]
  alert_email = var.alert_email
  environment = local.environment
  project     = local.project

  # data.aws_lambda_function reads inside this module must wait until functions exist.
  depends_on = [
    module.shorten_function,
    module.redirect_function,
    module.analytics_function,
  ]
}

# ── CloudTrail ────────────────────────────────────────────────────────────────

module "cloudtrail_bucket" {
  source = "../../modules/s3-bucket"

  bucket_name_suffix = "cloudtrail"
  environment        = local.environment
  project            = local.project
  enable_versioning  = false
  enable_website     = false
  log_bucket_id      = module.state_log_bucket.bucket_id
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = module.cloudtrail_bucket.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = module.cloudtrail_bucket.bucket_arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${module.cloudtrail_bucket.bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })
}

resource "aws_cloudtrail" "this" {
  name                          = "${local.name_prefix}-trail"
  s3_bucket_name                = module.cloudtrail_bucket.bucket_id
  enable_log_file_validation    = true
  include_global_service_events = true
  is_multi_region_trail         = false

  tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
