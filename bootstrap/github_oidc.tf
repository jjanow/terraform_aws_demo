# ── GitHub Actions OIDC ───────────────────────────────────────────────────────
# Apply this file once (terraform apply -target=...) after initial bootstrap to
# provision the OIDC provider and IAM role used by all CI workflows.
#
# Required variables: github_org, github_repo  (no defaults — fail loudly).
# Output github_actions_role_arn and store it as AWS_ROLE_ARN in your GitHub
# repository secrets.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS no longer validates these against the live cert chain but the field is
  # required by the Terraform schema.  Both thumbprints are published by GitHub.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals (not StringLike) keeps the subject claim an exact match.
    # Switch to StringLike only if you intentionally introduce wildcards like
    # repo:org/repo:ref:refs/heads/release/*.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.github_repo}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_role" {
  name               = "github-actions-role"
  path               = "/github-actions/"
  description        = "Assumed by GitHub Actions (OIDC) for ${var.github_org}/${var.github_repo}"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = {
    ManagedBy   = "terraform"
    Project     = var.project_name
    Environment = "bootstrap"
  }
}

# ── Permissions ────────────────────────────────────────────────────────────────
# Every statement is scoped to ARNs that begin with the project prefix so this
# role can only manage resources that belong to this stack. Where AWS does not
# expose resource-level permissions on every action (CloudFront, parts of API
# Gateway), the statement is intentionally narrowed by action set instead.

locals {
  account_id        = data.aws_caller_identity.current.account_id
  project_prefix    = var.project_name
  s3_bucket_arn     = "arn:aws:s3:::${local.project_prefix}-*"
  s3_object_arn     = "arn:aws:s3:::${local.project_prefix}-*/*"
  ddb_table_arn     = "arn:aws:dynamodb:*:${local.account_id}:table/${local.project_prefix}-*"
  ddb_index_arn     = "arn:aws:dynamodb:*:${local.account_id}:table/${local.project_prefix}-*/index/*"
  lambda_func_arn   = "arn:aws:lambda:*:${local.account_id}:function:${local.project_prefix}-*"
  log_group_lambda  = "arn:aws:logs:*:${local.account_id}:log-group:/aws/lambda/${local.project_prefix}-*"
  log_group_apigw   = "arn:aws:logs:*:${local.account_id}:log-group:/aws/apigateway/${local.project_prefix}-*"
  log_group_apigwwc = "arn:aws:logs:*:${local.account_id}:log-group:API-Gateway-Execution-Logs_*"
  sqs_arn           = "arn:aws:sqs:*:${local.account_id}:${local.project_prefix}-*"
  sns_arn           = "arn:aws:sns:*:${local.account_id}:${local.project_prefix}-*"
  cw_alarm_arn      = "arn:aws:cloudwatch:*:${local.account_id}:alarm:${local.project_prefix}-*"
  cw_dashboard_arn  = "arn:aws:cloudwatch::${local.account_id}:dashboard/${local.project_prefix}-*"
  cloudtrail_arn    = "arn:aws:cloudtrail:*:${local.account_id}:trail/${local.project_prefix}-*"
}

data "aws_iam_policy_document" "github_actions_permissions" {
  # ── S3 ───────────────────────────────────────────────────────────────────────
  # Scoped to project-prefixed buckets (covers Terraform state, log, and
  # application buckets like ${project}-bootstrap-state-${account_id},
  # ${project}-{env}-frontend-${account_id}, etc.).
  statement {
    sid    = "S3ProjectBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetObject*",
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListBucketVersions",
      "s3:PutBucketAcl",
      "s3:PutBucketCORS",
      "s3:PutBucketLogging",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutBucketWebsite",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:PutObjectTagging",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      local.s3_bucket_arn,
      local.s3_object_arn,
    ]
  }

  # ── DynamoDB ────────────────────────────────────────────────────────────────
  statement {
    sid    = "DynamoDBProjectTables"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:DescribeContributorInsights",
      "dynamodb:DescribeKinesisStreamingDestination",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:UpdateItem",
      "dynamodb:UpdateTable",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:UpdateTimeToLive",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:ListTagsOfResource",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = [
      local.ddb_table_arn,
      local.ddb_index_arn,
    ]
  }

  statement {
    sid       = "DynamoDBList"
    effect    = "Allow"
    actions   = ["dynamodb:ListTables"]
    resources = ["*"]
  }

  # ── Lambda ──────────────────────────────────────────────────────────────────
  statement {
    sid    = "LambdaProjectFunctions"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:GetFunction*",
      "lambda:ListFunctions",
      "lambda:ListVersionsByFunction",
      "lambda:PublishVersion",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
      "lambda:CreateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
      "lambda:UpdateEventSourceMapping",
      "lambda:InvokeFunction",
    ]
    resources = [
      local.lambda_func_arn,
      # Event source mappings get random UUID-based ARNs; mappings target a
      # specific project Lambda so this is bounded by who can call CreateEventSourceMapping.
      "arn:aws:lambda:*:${local.account_id}:event-source-mapping:*",
    ]
  }

  # ── API Gateway ─────────────────────────────────────────────────────────────
  # API Gateway resource ARNs use random API IDs that don't exist at policy
  # creation time, so we cannot scope by project prefix. Instead the action
  # set is narrowed to API-Gateway-only operations.
  statement {
    sid       = "APIGatewayManage"
    effect    = "Allow"
    actions   = ["apigateway:*"]
    resources = ["arn:aws:apigateway:*::/*"]
  }

  # ── IAM ─────────────────────────────────────────────────────────────────────
  # Full IAM control is scoped to the /github-actions/ path: this role itself
  # and any helper policies CI manages directly.
  statement {
    sid     = "IAMScopedToGithubActionsPath"
    effect  = "Allow"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/github-actions/*",
      "arn:aws:iam::${local.account_id}:policy/github-actions/*",
      "arn:aws:iam::${local.account_id}:instance-profile/github-actions/*",
    ]
  }

  # modules/lambda-function creates execution roles at the default IAM path "/"
  # named "${function_name}-role". Scoping by name pattern keeps this role from
  # tampering with arbitrary roles outside the project.
  statement {
    sid    = "IAMLambdaExecRoleLifecycle"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:PassRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.project_prefix}-*",
    ]
  }

  # Allow management of the OIDC provider and the github-actions-terraform-policy
  # so terraform can update its own bootstrap resources.
  statement {
    sid    = "IAMOIDCProvider"
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviderTags",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
    ]
  }

  # ── CloudWatch ──────────────────────────────────────────────────────────────
  statement {
    sid    = "CloudWatchAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = [local.cw_alarm_arn]
  }

  # CloudWatch dashboards are global (no region); the ARN format above
  # encodes the project-prefixed name.
  statement {
    sid    = "CloudWatchDashboards"
    effect = "Allow"
    actions = [
      "cloudwatch:GetDashboard",
      "cloudwatch:PutDashboard",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:ListDashboards",
    ]
    resources = [local.cw_dashboard_arn]
  }

  # ── CloudWatch Logs ─────────────────────────────────────────────────────────
  statement {
    sid    = "LogsProjectGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
      "logs:PutMetricFilter",
      "logs:DeleteMetricFilter",
      "logs:DescribeMetricFilters",
    ]
    resources = [
      local.log_group_lambda,
      "${local.log_group_lambda}:*",
      local.log_group_apigw,
      "${local.log_group_apigw}:*",
      local.log_group_apigwwc,
      "${local.log_group_apigwwc}:*",
    ]
  }

  # ── SNS ─────────────────────────────────────────────────────────────────────
  statement {
    sid    = "SNSProjectTopics"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:GetSubscriptionAttributes",
      "sns:SetSubscriptionAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTagsForResource",
      "sns:TagResource",
      "sns:UntagResource",
    ]
    resources = [local.sns_arn]
  }

  # ── SQS ─────────────────────────────────────────────────────────────────────
  statement {
    sid    = "SQSProjectQueues"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:SetQueueAttributes",
      "sqs:ListQueueTags",
      "sqs:TagQueue",
      "sqs:UntagQueue",
    ]
    resources = [local.sqs_arn]
  }

  # ── CloudFront ──────────────────────────────────────────────────────────────
  # CloudFront distribution IDs are random and not known at policy creation;
  # AWS supports `aws:ResourceTag/...` conditions on some CF actions but not
  # all. Scope by action set instead.
  statement {
    sid    = "CloudFrontManage"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution",
      "cloudfront:ListDistributions",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
    ]
    resources = ["*"]
  }

  # ── CloudTrail ──────────────────────────────────────────────────────────────
  statement {
    sid    = "CloudTrailProjectTrails"
    effect = "Allow"
    actions = [
      "cloudtrail:CreateTrail",
      "cloudtrail:DeleteTrail",
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrail",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:GetEventSelectors",
      "cloudtrail:PutEventSelectors",
      "cloudtrail:StartLogging",
      "cloudtrail:StopLogging",
      "cloudtrail:UpdateTrail",
      "cloudtrail:AddTags",
      "cloudtrail:RemoveTags",
      "cloudtrail:ListTags",
    ]
    resources = [local.cloudtrail_arn]
  }

  # ── SSM ─────────────────────────────────────────────────────────────────────
  statement {
    sid       = "SSMGetParameter"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:*:${local.account_id}:parameter/${local.project_prefix}/*"]
  }
}

resource "aws_iam_policy" "github_actions" {
  name        = "github-actions-terraform-policy"
  path        = "/github-actions/"
  description = "Terraform infrastructure permissions for GitHub Actions CI (${var.github_org}/${var.github_repo})"
  policy      = data.aws_iam_policy_document.github_actions_permissions.json
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = aws_iam_policy.github_actions.arn
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions; store this as AWS_ROLE_ARN in your repository secrets"
  value       = aws_iam_role.github_actions_role.arn
}
