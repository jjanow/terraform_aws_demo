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

    # StringLike (per spec) lets wildcard characters work if you extend this
    # list later, e.g. to match release/* branches.
    condition {
      test     = "StringLike"
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

data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid       = "S3"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]
  }

  statement {
    sid       = "DynamoDB"
    effect    = "Allow"
    actions   = ["dynamodb:*"]
    resources = ["*"]
  }

  statement {
    sid       = "Lambda"
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["*"]
  }

  statement {
    sid       = "APIGateway"
    effect    = "Allow"
    actions   = ["apigateway:*"]
    resources = ["*"]
  }

  # Full IAM control is scoped to the /github-actions/ path: this role itself,
  # any helper policies CI manages directly.
  statement {
    sid     = "IAMScopedToGithubActionsPath"
    effect  = "Allow"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/github-actions/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/github-actions/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/github-actions/*",
    ]
  }

  # modules/lambda-function creates execution roles at the default IAM path "/"
  # (no path variable in that module).  These narrower actions cover the full
  # Terraform lifecycle for those roles without granting iam:* on all resources.
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
    ]
    resources = ["*"]
  }

  statement {
    sid       = "CloudWatch"
    effect    = "Allow"
    actions   = ["cloudwatch:*"]
    resources = ["*"]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SNS"
    effect    = "Allow"
    actions   = ["sns:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SQS"
    effect    = "Allow"
    actions   = ["sqs:*"]
    resources = ["*"]
  }

  statement {
    sid       = "CloudFront"
    effect    = "Allow"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }

  statement {
    sid       = "CloudTrail"
    effect    = "Allow"
    actions   = ["cloudtrail:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SSMGetParameter"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["*"]
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
