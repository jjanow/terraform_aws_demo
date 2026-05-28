locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Keyed by "METHOD /path" for deterministic for_each keys
  integrations = {
    for i in var.lambda_integrations :
    "${i.http_method} ${i.resource_path}" => i
  }

  # All unique resource paths
  unique_paths = toset([for i in var.lambda_integrations : i.resource_path])

  # Unique first-level path segments (e.g. "users" from "/users" or "/users/{id}")
  level1_segments = toset([
    for p in local.unique_paths : split("/", trimprefix(p, "/"))[0]
  ])

  # Two-segment paths keyed by "seg1/seg2" (no leading slash)
  level2_paths = {
    for p in local.unique_paths :
    trimprefix(p, "/") => {
      parent_segment = split("/", trimprefix(p, "/"))[0]
      child_segment  = split("/", trimprefix(p, "/"))[1]
    }
    if length(split("/", trimprefix(p, "/"))) == 2
  }

  # Per-path metadata used to resolve the correct resource collection and key
  path_meta = {
    for p in local.unique_paths : p => {
      is_level2  = length(split("/", trimprefix(p, "/"))) == 2
      level1_key = split("/", trimprefix(p, "/"))[0]
      level2_key = trimprefix(p, "/")
    }
  }

  # Subset of integrations that carry a JSON request schema
  schema_integrations = {
    for k, i in local.integrations : k => i
    if i.request_schema_json != null
  }
}

# ── CloudWatch log group ────────────────────────────────────────────────────────
# PREREQUISITE: aws_api_gateway_account with a CloudWatch Logs push role must
# exist at the account level before access logging will emit records. This
# module does not manage aws_api_gateway_account to avoid cross-module conflicts;
# create it once in the root configuration (mirrors the s3-bucket module pattern).

resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/aws/apigateway/${var.api_name}"
  retention_in_days = 14

  tags = local.tags
}

# ── REST API ───────────────────────────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "this" {
  name        = var.api_name
  description = var.description

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.tags
}

# ── Request validator ──────────────────────────────────────────────────────────

resource "aws_api_gateway_request_validator" "body" {
  name                  = "${var.api_name}-body-validator"
  rest_api_id           = aws_api_gateway_rest_api.this.id
  validate_request_body = true
}

# ── Models (request schemas) ───────────────────────────────────────────────────

resource "aws_api_gateway_model" "this" {
  for_each = local.schema_integrations

  rest_api_id = aws_api_gateway_rest_api.this.id
  # Model names must be alphanumeric; strip all non-word characters from the key
  name = replace(replace(replace(replace(replace(
    "${each.value.http_method}${each.value.resource_path}",
  "/", ""), "{", ""), "}", ""), "-", ""), "_", "")
  content_type = "application/json"
  schema       = each.value.request_schema_json
}

# ── Path resources ─────────────────────────────────────────────────────────────

resource "aws_api_gateway_resource" "level1" {
  for_each = local.level1_segments

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = each.key
}

resource "aws_api_gateway_resource" "level2" {
  for_each = local.level2_paths

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.level1[each.value.parent_segment].id
  path_part   = each.value.child_segment
}

# Convenience map: resource_path → aws_api_gateway_resource id
locals {
  path_resource_ids = {
    for p, m in local.path_meta :
    p => (m.is_level2
      ? aws_api_gateway_resource.level2[m.level2_key].id
      : aws_api_gateway_resource.level1[m.level1_key].id
    )
  }
}

# ── Methods ─────────────────────────────────────────────────────────────────────

resource "aws_api_gateway_method" "this" {
  for_each = local.integrations

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = local.path_resource_ids[each.value.resource_path]
  http_method   = each.value.http_method
  authorization = "NONE"

  request_validator_id = each.value.request_schema_json != null ? aws_api_gateway_request_validator.body.id : null
  request_models       = each.value.request_schema_json != null ? { "application/json" = aws_api_gateway_model.this[each.key].name } : {}
}

# ── Lambda integrations (proxy) ────────────────────────────────────────────────

resource "aws_api_gateway_integration" "this" {
  for_each = local.integrations

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = local.path_resource_ids[each.value.resource_path]
  http_method             = aws_api_gateway_method.this[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = each.value.lambda_invoke_arn
}

# ── Method responses ───────────────────────────────────────────────────────────

resource "aws_api_gateway_method_response" "this" {
  for_each = local.integrations

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = local.path_resource_ids[each.value.resource_path]
  http_method = aws_api_gateway_method.this[each.key].http_method
  status_code = "200"

  response_parameters = {
    # false = header is allowed but not required; Lambda sets it in the response
    "method.response.header.Access-Control-Allow-Origin" = false
  }

  depends_on = [aws_api_gateway_method.this]
}

# ── Integration responses ──────────────────────────────────────────────────────
# AWS_PROXY passes the Lambda response through unchanged; these resources satisfy
# the module contract. Note: response mappings have no effect for proxy
# integrations — CORS for actual methods is set by the Lambda function itself.

resource "aws_api_gateway_integration_response" "this" {
  for_each = local.integrations

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = local.path_resource_ids[each.value.resource_path]
  http_method = aws_api_gateway_method.this[each.key].http_method
  status_code = aws_api_gateway_method_response.this[each.key].status_code

  depends_on = [aws_api_gateway_integration.this, aws_api_gateway_method_response.this]
}

# ── CORS — OPTIONS methods (MOCK integration) ──────────────────────────────────

resource "aws_api_gateway_method" "options" {
  for_each = local.unique_paths

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = local.path_resource_ids[each.key]
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options" {
  for_each = local.unique_paths

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = local.path_resource_ids[each.key]
  http_method = aws_api_gateway_method.options[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "options" {
  for_each = local.unique_paths

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = local.path_resource_ids[each.key]
  http_method = aws_api_gateway_method.options[each.key].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = false
    "method.response.header.Access-Control-Allow-Methods" = false
    "method.response.header.Access-Control-Allow-Origin"  = false
  }

  depends_on = [aws_api_gateway_method.options]
}

resource "aws_api_gateway_integration_response" "options" {
  for_each = local.unique_paths

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = local.path_resource_ids[each.key]
  http_method = aws_api_gateway_method.options[each.key].http_method
  status_code = aws_api_gateway_method_response.options[each.key].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,PUT,DELETE,PATCH,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  response_templates = {
    "application/json" = ""
  }

  depends_on = [aws_api_gateway_integration.options, aws_api_gateway_method_response.options]
}

# ── Deployment ─────────────────────────────────────────────────────────────────
# triggers hash covers every method/integration so that any API config change
# creates a new deployment and the stage is automatically updated.

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.level1,
      aws_api_gateway_resource.level2,
      aws_api_gateway_method.this,
      aws_api_gateway_integration.this,
      aws_api_gateway_method_response.this,
      aws_api_gateway_integration_response.this,
      aws_api_gateway_method.options,
      aws_api_gateway_integration.options,
      aws_api_gateway_method_response.options,
      aws_api_gateway_integration_response.options,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Stage ──────────────────────────────────────────────────────────────────────

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
    })
  }

  tags = local.tags
}

# ── Throttling ─────────────────────────────────────────────────────────────────
# method_path "*/*" applies the limits to every method in the stage.

resource "aws_api_gateway_method_settings" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_burst_limit = var.burst_limit
    throttling_rate_limit  = var.rate_limit
  }
}

# ── Lambda invoke permissions ──────────────────────────────────────────────────

resource "aws_lambda_permission" "this" {
  for_each = local.integrations

  # Strip non-alphanumeric/hyphen chars that are invalid in statement_id
  statement_id = replace(replace(replace(
    "AllowAPIGW-${each.value.http_method}${each.value.resource_path}",
  "/", "-"), "{", ""), "}", "")
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  # Scoped to this API + any stage + this specific method and path (least-privilege)
  source_arn = "${aws_api_gateway_rest_api.this.execution_arn}/*/${each.value.http_method}${each.value.resource_path}"
}
