locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Caller-supplied vars win over the default so the variable isn't a lie.
  effective_env_vars = merge(
    { POWERTOOLS_LOG_LEVEL = "INFO" },
    var.environment_variables,
  )
}

# ── Source archive ──────────────────────────────────────────────────────────────

data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.terraform/tmp/${var.function_name}.zip"
}

# ── IAM role ────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = local.tags
}

# ── Managed policy attachments ──────────────────────────────────────────────────

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

# ── Inline policy (optional) ────────────────────────────────────────────────────

resource "aws_iam_role_policy" "inline" {
  count = var.inline_policy_json != null ? 1 : 0

  name   = "${var.function_name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}

# ── CloudWatch log group ────────────────────────────────────────────────────────
#
# Must be created before the function so Lambda does not race ahead and create
# an un-retained log group on first invocation.

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

# ── Lambda function ─────────────────────────────────────────────────────────────

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = var.description

  role    = aws_iam_role.this.arn
  runtime = var.runtime
  handler = var.handler

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  memory_size = var.memory_size
  timeout     = var.timeout

  environment {
    variables = local.effective_env_vars
  }

  tags = local.tags

  # Guarantees the log group (with retention) exists before the function is
  # created, preventing Lambda from auto-creating an unretained group.
  depends_on = [aws_cloudwatch_log_group.this]
}
