data "aws_region" "current" {}

# Read each Lambda function so the duration alarm threshold can be derived from
# each function's configured timeout without changing the input variable shape.
data "aws_lambda_function" "this" {
  for_each      = toset(var.function_names)
  function_name = each.key
}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Custom metric namespace used for log-derived error counts.
  metric_namespace = "${var.project}/${var.environment}"

  # ── Dashboard metric arrays ─────────────────────────────────────────────────
  # Each entry is a CloudWatch metrics array element: [Namespace, MetricName,
  # DimName, DimValue, {options}]. Terraform serialises mixed-type tuples
  # correctly via jsonencode.

  lambda_invocation_metrics = [
    for fn in var.function_names :
    ["AWS/Lambda", "Invocations", "FunctionName", fn, { stat = "Sum", label = fn }]
  ]

  lambda_error_metrics = [
    for fn in var.function_names :
    ["AWS/Lambda", "Errors", "FunctionName", fn, { stat = "Sum", label = fn }]
  ]

  lambda_duration_metrics = [
    for fn in var.function_names :
    ["AWS/Lambda", "Duration", "FunctionName", fn, { stat = "p99", label = fn }]
  ]

  dynamodb_read_metrics = [
    for t in var.dynamodb_table_names :
    ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", t, { stat = "Sum", label = t }]
  ]

  dynamodb_write_metrics = [
    for t in var.dynamodb_table_names :
    ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", t, { stat = "Sum", label = t }]
  ]

  dynamodb_widgets = length(var.dynamodb_table_names) > 0 ? [
    {
      type   = "metric"
      x      = 0
      y      = 12
      width  = 12
      height = 6
      properties = {
        title   = "DynamoDB Consumed Read Capacity"
        metrics = local.dynamodb_read_metrics
        period  = 60
        view    = "timeSeries"
        region  = data.aws_region.current.name
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 12
      width  = 12
      height = 6
      properties = {
        title   = "DynamoDB Consumed Write Capacity"
        metrics = local.dynamodb_write_metrics
        period  = 60
        view    = "timeSeries"
        region  = data.aws_region.current.name
      }
    },
  ] : []

  dashboard_body = jsonencode({
    widgets = concat(
      [
        # ── Row 1: Lambda ───────────────────────────────────────────────────
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 8
          height = 6
          properties = {
            title   = "Lambda Invocations"
            metrics = local.lambda_invocation_metrics
            period  = 60
            view    = "timeSeries"
            region  = data.aws_region.current.name
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 0
          width  = 8
          height = 6
          properties = {
            title   = "Lambda Errors"
            metrics = local.lambda_error_metrics
            period  = 60
            view    = "timeSeries"
            region  = data.aws_region.current.name
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 0
          width  = 8
          height = 6
          properties = {
            title   = "Lambda Duration (P99)"
            metrics = local.lambda_duration_metrics
            period  = 60
            view    = "timeSeries"
            region  = data.aws_region.current.name
          }
        },
        # ── Row 2: API Gateway ─────────────────────────────────────────────
        {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 8
          height = 6
          properties = {
            title   = "API Gateway Request Count"
            metrics = [["AWS/ApiGateway", "Count", "ApiName", var.api_gateway_name, { stat = "Sum" }]]
            period  = 60
            view    = "timeSeries"
            region  = data.aws_region.current.name
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 6
          width  = 8
          height = 6
          properties = {
            title = "API Gateway Latency"
            metrics = [
              ["AWS/ApiGateway", "Latency", "ApiName", var.api_gateway_name, { stat = "p99", label = "P99" }],
              ["AWS/ApiGateway", "Latency", "ApiName", var.api_gateway_name, { stat = "Average", label = "Average" }],
            ]
            period = 60
            view   = "timeSeries"
            region = data.aws_region.current.name
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 6
          width  = 8
          height = 6
          properties = {
            title = "API Gateway Errors"
            metrics = [
              ["AWS/ApiGateway", "5XXError", "ApiName", var.api_gateway_name, { stat = "Sum", label = "5XX" }],
              ["AWS/ApiGateway", "4XXError", "ApiName", var.api_gateway_name, { stat = "Sum", label = "4XX" }],
            ]
            period = 60
            view   = "timeSeries"
            region = data.aws_region.current.name
          }
        },
      ],
      # ── Row 3: DynamoDB (omitted when no tables are provided) ──────────────
      local.dynamodb_widgets,
    )
  })
}

# ── SNS ──────────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "alarms" {
  name = "${var.project}-${var.environment}-alarms"
  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Log metric filters ───────────────────────────────────────────────────────────
# The lambda-function module already creates /aws/lambda/<name> log groups with
# 14-day retention; this module only attaches filters — it does not re-declare
# those log groups.
# Pattern targets Lambda Powertools structured JSON: {"level":"ERROR",...}

resource "aws_cloudwatch_log_metric_filter" "lambda_errors" {
  for_each = toset(var.function_names)

  name           = "${each.key}-error-log-count"
  log_group_name = "/aws/lambda/${each.key}"
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = "${each.key}-LogErrorCount"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# ── Lambda alarms ────────────────────────────────────────────────────────────────

# Error rate: metric math produces errors/invocations*100 per minute; alarm fires
# when every one of the 5 evaluated 1-minute windows exceeds 5%.
resource "aws_cloudwatch_metric_alarm" "lambda_error_rate" {
  for_each = toset(var.function_names)

  alarm_name          = "${each.key}-error-rate"
  alarm_description   = "Lambda error rate > 5% for 5 consecutive minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "errors"
    metric {
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = 60
      stat        = "Sum"
      dimensions  = { FunctionName = each.key }
    }
  }

  metric_query {
    id = "invocations"
    metric {
      metric_name = "Invocations"
      namespace   = "AWS/Lambda"
      period      = 60
      stat        = "Sum"
      dimensions  = { FunctionName = each.key }
    }
  }

  metric_query {
    id          = "error_rate"
    expression  = "IF(invocations > 0, errors / invocations * 100, 0)"
    label       = "Error Rate (%)"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.tags
}

# Throttles: any single 1-minute window with throttles in a 5-minute observation
# window triggers the alarm (datapoints_to_alarm = 1).
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = toset(var.function_names)

  alarm_name          = "${each.key}-throttles"
  alarm_description   = "Lambda throttles detected in 5-minute window"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 1
  period              = 60
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/Lambda"
  metric_name = "Throttles"
  statistic   = "Sum"
  dimensions  = { FunctionName = each.key }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.tags
}

# Duration: threshold is 80% of each function's timeout, converted from seconds
# (Lambda config) to milliseconds (CloudWatch Duration metric unit).
resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  for_each = toset(var.function_names)

  alarm_name          = "${each.key}-duration"
  alarm_description   = "Lambda P99 duration > 80% of configured timeout for 5 consecutive minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = data.aws_lambda_function.this[each.key].timeout * 1000 * 0.8
  evaluation_periods  = 5
  period              = 60
  treat_missing_data  = "notBreaching"

  namespace          = "AWS/Lambda"
  metric_name        = "Duration"
  extended_statistic = "p99"
  dimensions         = { FunctionName = each.key }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.tags
}

# Log error count: any 1-minute window with ERROR log events in a 5-minute
# observation window triggers the alarm (datapoints_to_alarm = 1).
resource "aws_cloudwatch_metric_alarm" "lambda_log_errors" {
  for_each = toset(var.function_names)

  alarm_name          = "${each.key}-log-errors"
  alarm_description   = "ERROR-level log events detected in 5-minute window"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 1
  period              = 60
  treat_missing_data  = "notBreaching"

  namespace   = local.metric_namespace
  metric_name = "${each.key}-LogErrorCount"
  statistic   = "Sum"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.tags

  depends_on = [aws_cloudwatch_log_metric_filter.lambda_errors]
}

# ── API Gateway alarms ───────────────────────────────────────────────────────────

# 5xx rate: metric math over 1-minute sums; fires when every window in 5 minutes
# exceeds 1%. Dimensions use ApiName only (aggregates across stages).
resource "aws_cloudwatch_metric_alarm" "apigw_5xx_rate" {
  alarm_name          = "${var.api_gateway_name}-5xx-error-rate"
  alarm_description   = "API Gateway 5xx error rate > 1% for 5 consecutive minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "errors"
    metric {
      metric_name = "5XXError"
      namespace   = "AWS/ApiGateway"
      period      = 60
      stat        = "Sum"
      dimensions  = { ApiName = var.api_gateway_name }
    }
  }

  metric_query {
    id = "requests"
    metric {
      metric_name = "Count"
      namespace   = "AWS/ApiGateway"
      period      = 60
      stat        = "Sum"
      dimensions  = { ApiName = var.api_gateway_name }
    }
  }

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, errors / requests * 100, 0)"
    label       = "5XX Error Rate (%)"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "apigw_latency_p99" {
  alarm_name          = "${var.api_gateway_name}-latency-p99"
  alarm_description   = "API Gateway P99 latency > 3000ms for 5 consecutive minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 3000
  evaluation_periods  = 5
  period              = 60
  treat_missing_data  = "notBreaching"

  namespace          = "AWS/ApiGateway"
  metric_name        = "Latency"
  extended_statistic = "p99"
  dimensions         = { ApiName = var.api_gateway_name }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
  tags          = local.tags
}

# ── Dashboard ─────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.project}-${var.environment}"
  dashboard_body = local.dashboard_body
}
