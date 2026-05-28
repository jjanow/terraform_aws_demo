# terraform-aws-demo

A production-grade serverless URL shortener built to demonstrate Terraform module design, environment separation, CI/CD with GitHub OIDC, and AWS cost discipline.

---

## Architecture

```
                              ┌─────────────────────────────────────────────────────┐
                              │                    CloudFront                       │
                              │              (CDN + TLS termination)                │
                              └────────────────────────┬────────────────────────────┘
                                                       │
                              ┌────────────────────────┴────────────────────────────┐
                              │                                                     │
                    ┌─────────▼──────────┐                         ┌───────────────▼──────────────┐
                    │   S3 (Frontend)    │                         │       API Gateway (REST)      │
                    │  Static HTML/JS/   │                         │       /api/* path behavior    │
                    │  CSS assets        │                         └───────────────┬──────────────┘
                    └────────────────────┘                                         │
                                                                   ┌───────────────┴──────────────┐
                                                                   │                              │
                                                        ┌──────────▼──────────┐   ┌──────────────▼──────────┐
                                                        │  Lambda: shorten    │   │   Lambda: redirect      │
                                                        │  POST /api/shorten  │   │   GET /api/{short_code} │
                                                        └──────────┬──────────┘   └──────────────┬──────────┘
                                                                   │                              │
                                                        ┌──────────▼──────────────────────────────▼──────────┐
                                                        │                DynamoDB: urls_table                │
                                                        │         (short_code PK, by_owner GSI, TTL)        │
                                                        └──────────┬──────────────────────────────┬──────────┘
                                                                   │ async                         │ async
                                                        ┌──────────▼──────────┐   ┌──────────────▼──────────┐
                                                        │  SQS: click_events  │   │  SQS: click_events_dlq  │
                                                        │  (analytics queue)  │   │  (dead-letter, 3 retries)│
                                                        └──────────┬──────────┘   └─────────────────────────┘
                                                                   │
                                                        ┌──────────▼──────────┐
                                                        │  Lambda: analytics  │
                                                        │  (SQS event source) │
                                                        └──────────┬──────────┘
                                                                   │
                                                        ┌──────────▼──────────┐
                                                        │ DynamoDB: analytics │
                                                        │ (short_code PK,     │
                                                        │  timestamp SK, TTL) │
                                                        └─────────────────────┘

Request flow
────────────
User ──► CloudFront ──► S3 (static assets, default behavior)
                   └──► API Gateway (/api/* behavior)
                             ├──► Lambda: shorten  ──► DynamoDB urls_table
                             │                     └──► SQS (async) ──► Lambda: analytics ──► DynamoDB analytics_table
                             └──► Lambda: redirect ──► DynamoDB urls_table
                                                   └──► SQS (async) ──► Lambda: analytics ──► DynamoDB analytics_table
```

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| AWS CLI | >= 2.x | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Terraform | >= 1.7 | https://developer.hashicorp.com/terraform/install |
| Python | 3.12 | https://www.python.org/downloads/ (only needed to run Lambda functions locally) |

You also need an AWS account with permissions to create IAM roles, S3 buckets, DynamoDB tables, Lambda functions, API Gateway, CloudFront distributions, SQS queues, SNS topics, CloudWatch alarms, and CloudTrail trails.

---

## Deployment

### 1. Fork and clone

```bash
git clone https://github.com/<your-org>/terraform-aws-demo.git
cd terraform-aws-demo
```

### 2. Bootstrap remote state

The `bootstrap/` directory creates the S3 bucket and DynamoDB table that store all other Terraform state. Run this once per AWS account.

Bootstrap requires four input variables:

| Variable | Description | Example |
|---|---|---|
| `project_name` | Prefix for all resource names (≤ 34 chars) | `tf-demo` |
| `github_org` | GitHub organization or username that owns the repo | `my-org` |
| `github_repo` | GitHub repository name | `terraform-aws-demo` |
| `aws_region` | AWS region to deploy into (default: `us-east-1`) | `us-east-1` |

To avoid interactive prompts, create a `bootstrap/terraform.tfvars` file before applying:

```hcl
project_name = "tf-demo"
github_org   = "my-org"
github_repo  = "terraform-aws-demo"
```

Then run:

```bash
cd bootstrap
terraform init
terraform apply
```

Note the outputs — you will need them in the next step:

```
state_bucket_name   = "tf-demo-bootstrap-state-<account-id>"
dynamodb_table_name = "tf-demo-bootstrap-lock"
log_bucket_name     = "tf-demo-bootstrap-logs-<account-id>"
```

### 3. Update backend configuration

Edit [environments/dev/backend.tf](environments/dev/backend.tf) and [environments/prod/backend.tf](environments/prod/backend.tf) with the output values from step 2:

```hcl
terraform {
  backend "s3" {
    bucket         = "tf-demo-bootstrap-state-<account-id>"   # from step 2
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-demo-bootstrap-lock"                  # from step 2
    encrypt        = true
  }
}
```

### 4. Set up GitHub OIDC authentication

Create the IAM role that GitHub Actions will assume via OIDC:

```bash
cd bootstrap
terraform apply -target=aws_iam_role.github_actions_role
```

Note the `github_actions_role_arn` from the output.

### 5. Add GitHub repository secrets

In your repository → Settings → Secrets and variables → Actions, add:

| Secret name | Value |
|---|---|
| `AWS_ROLE_ARN` | Role ARN from step 4 (e.g., `arn:aws:iam::<account-id>:role/github-actions/github-actions-role`) |
| `TF_STATE_BUCKET` | State bucket name from step 2 |

### 6. Push to main — CI/CD handles the rest

```bash
git push origin main
```

- **Pull requests** → `terraform-plan.yml` runs `terraform fmt` check, tfsec, Checkov, and posts a plan as a PR comment.
- **Merge to main** → `terraform-apply.yml` requires manual approval in the GitHub "production" environment, then applies to prod.

---

## Cost

All services used fall within the AWS Free Tier or have usage-based pricing with no minimum charge. At zero traffic this architecture costs **$0/month**.

| Service | Tier | Monthly cost |
|---|---|---|
| S3 | 5 GB storage, 20k GET, 2k PUT requests free | $0 |
| CloudFront | 1 TB transfer + 10M HTTP requests/month free | $0 |
| API Gateway (REST) | 1M API calls/month free (12 months) | $0 |
| Lambda | 1M requests + 400k GB-seconds/month always free | $0 |
| DynamoDB | 25 GB storage + 200M requests/month always free | $0 |
| SQS | 1M requests/month always free | $0 |
| CloudWatch | 10 metrics, 10 alarms, 5 GB logs/month free | $0 |
| SNS | 1M publishes/month free | $0 |
| CloudTrail | One free management-events trail per region | $0 |
| IAM | Always free | $0 |

### Cost Traps Avoided

This project deliberately avoids four common sources of unexpected AWS bills:

**NAT Gateway** — Not used. Lambda functions run without VPC attachment so they reach DynamoDB, SQS, and other AWS services over public endpoints directly. NAT Gateways cost ~$32/month at minimum plus $0.045/GB data processing regardless of traffic.

**Unattached Elastic IPs** — Not used. This architecture has no EC2 instances or load balancers, so there are no Elastic IPs that could be allocated and forgotten after a resource is deleted. Unattached EIPs are charged $0.005/hour (~$3.60/month each).

**Unbounded CloudWatch Logs** — All Lambda log groups are created explicitly by Terraform with a `log_retention_days` variable (14 days in dev, 30 in prod). Without explicit retention, Lambda auto-creates log groups with infinite retention and log storage accumulates indefinitely at $0.03/GB/month.

**GuardDuty Trial Timer** — GuardDuty is not enabled in this project. Enabling it via the AWS console starts an automatic 30-day free trial; after the trial expires charges begin at roughly $1–$4/day depending on CloudTrail volume. Threat detection for this demo is handled through CloudTrail log review and CloudWatch alarms instead.

---

## Security Posture

| Control | Implementation |
|---|---|
| No long-lived credentials | GitHub Actions authenticates via OIDC; no AWS access keys are stored as GitHub secrets |
| Least-privilege IAM | GitHub Actions role is scoped to specific resource path prefixes; each Lambda has an inline policy granting only the permissions that function requires |
| Encryption at rest | All S3 buckets use AES-256 SSE; DynamoDB uses AWS-owned keys; Terraform state bucket uses SSE |
| Encryption in transit | CloudFront enforces HTTPS; API Gateway endpoints are HTTPS-only |
| Remote state locking | DynamoDB lock table prevents concurrent `terraform apply` runs from corrupting state |
| State access logging | Bootstrap S3 log bucket captures all access to the state bucket |
| CloudTrail audit log | All AWS API calls are logged to S3 with log-file validation enabled |
| DynamoDB deletion protection | Enabled on prod tables; prevents accidental `terraform destroy` of live data |
| S3 public access block | All buckets have `block_public_acls`, `block_public_policy`, `ignore_public_acls`, and `restrict_public_buckets` set to `true`; CloudFront serves the frontend via OAC |
| API request validation | API Gateway validates request bodies against JSON schemas before invoking Lambda |
| CORS restricted | CloudFront and API Gateway CORS headers are scoped to configured origins |
| CloudWatch alarms | Alerts fire on Lambda error rate > 5%, any throttles, P99 duration > 80% of timeout; API Gateway 5xx > 1%, latency P99 > 3 s |
| SQS dead-letter queue | Unprocessable analytics events are retried 3 times before routing to DLQ for manual investigation |
| TTL on all records | DynamoDB URL and analytics records expire after 90 days; tables cannot grow without bound |
| Static analysis on every PR | `terraform fmt -check`, tfsec, and Checkov must pass before a plan is posted |

---

## Module Reference

### `modules/s3-bucket`

Opinionated S3 bucket with enforced encryption, public access block, and optional website hosting, versioning, access logging, and CORS.

**Inputs**

| Name | Type | Default | Description |
|---|---|---|---|
| `bucket_name_suffix` | `string` | — | Short suffix appended after project and environment |
| `environment` | `string` | — | Deployment environment (dev, prod) |
| `project` | `string` | — | Project name used in bucket name and tags |
| `enable_versioning` | `bool` | `true` | Enable S3 object versioning |
| `enable_website` | `bool` | `false` | Enable static website hosting |
| `website_index_document` | `string` | `"index.html"` | Index document for website hosting |
| `cors_allowed_origins` | `list(string)` | `[]` | Origins allowed for CORS GET/HEAD requests |
| `log_bucket_id` | `string` | `null` | Bucket ID to receive access logs |
| `force_destroy` | `bool` | `false` | Allow Terraform to delete a non-empty bucket |

**Outputs**

| Name | Description |
|---|---|
| `bucket_id` | Name (ID) of the S3 bucket |
| `bucket_arn` | ARN of the S3 bucket |
| `bucket_regional_domain_name` | Regional domain name for use as a CloudFront origin |

---

### `modules/lambda-function`

Lambda function with a pre-created CloudWatch log group (explicit retention), IAM execution role, optional managed and inline policy attachments, and environment variable injection.

**Inputs**

| Name | Type | Default | Description |
|---|---|---|---|
| `function_name` | `string` | — | Name of the Lambda function |
| `description` | `string` | — | Human-readable function description |
| `handler` | `string` | — | Entrypoint in `file.function` format (e.g., `index.handler`) |
| `runtime` | `string` | `"python3.12"` | Lambda runtime identifier |
| `source_dir` | `string` | — | Path to directory containing function source code |
| `environment_variables` | `map(string)` | `{}` | Environment variables (merged with `POWERTOOLS_LOG_LEVEL=INFO`) |
| `memory_size` | `number` | `128` | Memory in MB |
| `timeout` | `number` | `30` | Maximum execution time in seconds |
| `additional_policy_arns` | `list(string)` | `[]` | Managed policy ARNs to attach alongside BasicExecutionRole |
| `inline_policy_json` | `string` | `null` | JSON string for an inline IAM policy |
| `log_retention_days` | `number` | `14` | CloudWatch log retention in days |
| `environment` | `string` | — | Deployment environment |
| `project` | `string` | — | Project name for tags |

**Outputs**

| Name | Description |
|---|---|
| `function_arn` | ARN of the Lambda function |
| `function_name` | Name of the Lambda function |
| `invoke_arn` | Invoke ARN for use in API Gateway integrations |
| `role_arn` | ARN of the Lambda execution IAM role |
| `role_name` | Name of the Lambda execution IAM role |

---

### `modules/api-gateway`

Regional REST API with Lambda proxy integrations, automatic CORS preflight handling, CloudWatch access logging, per-stage throttling, and optional request body validation via JSON schema.

**Inputs**

| Name | Type | Default | Description |
|---|---|---|---|
| `api_name` | `string` | — | Name of the REST API |
| `description` | `string` | — | API description |
| `stage_name` | `string` | — | Deployment stage name (e.g., `v1`) |
| `burst_limit` | `number` | `100` | Maximum burst request count |
| `rate_limit` | `number` | `50` | Steady-state requests per second |
| `lambda_integrations` | `list(object)` | — | See integration schema below |
| `environment` | `string` | — | Deployment environment |
| `project` | `string` | — | Project name for tags |

`lambda_integrations` object schema:

| Field | Type | Required | Description |
|---|---|---|---|
| `http_method` | `string` | yes | HTTP verb (GET, POST, etc.) |
| `resource_path` | `string` | yes | Path (e.g., `/api/shorten`, `/api/{short_code}`) |
| `lambda_invoke_arn` | `string` | yes | Lambda invoke ARN |
| `lambda_function_name` | `string` | yes | Function name for the Lambda permission resource |
| `request_schema_json` | `string` | no | JSON schema string for request body validation |

**Outputs**

| Name | Description |
|---|---|
| `api_id` | ID of the REST API |
| `api_arn` | ARN of the REST API |
| `invoke_url` | Base invocation URL including stage (e.g., `https://<id>.execute-api.us-east-1.amazonaws.com/v1`) |
| `execution_arn` | Execution ARN of the deployed stage |

---

### `modules/dynamodb-table`

DynamoDB table with on-demand billing, point-in-time recovery, optional TTL, optional GSIs, and automatic deletion protection for production environments.

**Inputs**

| Name | Type | Default | Description |
|---|---|---|---|
| `table_name` | `string` | — | Table name |
| `hash_key` | `string` | — | Partition key attribute name |
| `hash_key_type` | `string` | `"S"` | Partition key type: `S`, `N`, or `B` |
| `range_key` | `string` | `null` | Sort key attribute name |
| `range_key_type` | `string` | `"S"` | Sort key type: `S`, `N`, or `B` |
| `ttl_attribute` | `string` | `null` | Attribute name for TTL-based item expiry |
| `global_secondary_indexes` | `list(object)` | `[]` | GSI definitions (see below) |
| `environment` | `string` | — | Deployment environment |
| `project` | `string` | — | Project name for tags |

`global_secondary_indexes` object schema:

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | `string` | yes | GSI name |
| `hash_key` | `string` | yes | GSI partition key attribute name |
| `range_key` | `string` | no | GSI sort key attribute name |
| `projection_type` | `string` | yes | `ALL`, `KEYS_ONLY`, or `INCLUDE` |

**Outputs**

| Name | Description |
|---|---|
| `table_name` | Name of the DynamoDB table |
| `table_arn` | ARN of the DynamoDB table |
| `table_id` | ID of the DynamoDB table (same as name) |

---

### `modules/cloudwatch-monitoring`

SNS alarm topic with email subscription, Lambda error-rate/throttle/duration/log-error alarms, API Gateway 5xx and latency P99 alarms, structured-log metric filters for Lambda Powertools JSON, and a CloudWatch dashboard.

**Inputs**

| Name | Type | Default | Description |
|---|---|---|---|
| `function_names` | `list(string)` | — | Lambda function names to monitor |
| `api_gateway_name` | `string` | — | REST API name to monitor |
| `dynamodb_table_names` | `list(string)` | `[]` | Table names to include in dashboard capacity widgets |
| `alert_email` | `string` | — | Email address for SNS alarm subscriptions |
| `environment` | `string` | — | Deployment environment |
| `project` | `string` | — | Project name for resource names and tags |

**Outputs**

| Name | Description |
|---|---|
| `sns_topic_arn` | ARN of the SNS alarm notification topic |
| `dashboard_name` | Name of the CloudWatch dashboard |

---

## Repository Layout

```
.
├── bootstrap/              # One-time setup: state bucket, DynamoDB lock table, GitHub OIDC role
├── environments/
│   ├── dev/                # Dev root module (backend.tf, main.tf, variables.tf, outputs.tf)
│   └── prod/               # Prod root module
├── modules/
│   ├── api-gateway/
│   ├── cloudwatch-monitoring/
│   ├── dynamodb-table/
│   ├── lambda-function/
│   └── s3-bucket/
├── src/functions/
│   ├── analytics/          # SQS-triggered click analytics processor
│   ├── redirect/           # GET /api/{short_code} → 301 redirect
│   └── shorten/            # POST /api/shorten → create short URL
└── .github/workflows/
    ├── terraform-plan.yml  # Lint + security scan + plan on PR
    └── terraform-apply.yml # Apply to prod on merge to main (requires approval)
```

## Notes on `.tfvars` files

The `terraform.tfvars` files in `environments/dev/` and `environments/prod/` are committed to version control because they contain only non-sensitive placeholder values (`project` and `alert_email`). Do **not** commit any `.tfvars` file that contains secrets, access keys, or private data. Use `*.secret.tfvars` or `secrets.auto.tfvars` naming conventions for sensitive variable files and ensure those patterns are listed in `.gitignore`.
