# s3-bucket module

Opinionated S3 bucket with enforced security defaults. Every bucket created
by this module gets SSE-S3 encryption and a full public-access block — neither
can be disabled by callers.

## Usage

```hcl
module "assets" {
  source = "../modules/s3-bucket"

  project            = "myapp"
  environment        = "prod"
  bucket_name_suffix = "assets"
}
```

With access logging, versioning off, and CORS:

```hcl
module "uploads" {
  source = "../modules/s3-bucket"

  project            = "myapp"
  environment        = "dev"
  bucket_name_suffix = "uploads"

  enable_versioning    = false
  log_bucket_id        = module.logs.bucket_id
  cors_allowed_origins = ["https://app.example.com"]
}
```

Static website bucket:

```hcl
module "site" {
  source = "../modules/s3-bucket"

  project            = "myapp"
  environment        = "prod"
  bucket_name_suffix = "site"

  enable_website         = true
  website_index_document = "index.html"
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `bucket_name_suffix` | `string` | — | Short suffix appended after project and environment in the bucket name |
| `environment` | `string` | — | Deployment environment (e.g. dev, staging, prod) |
| `project` | `string` | — | Project name used in the bucket name and tags |
| `enable_versioning` | `bool` | `true` | Enable S3 versioning |
| `enable_website` | `bool` | `false` | Enable static website hosting (see security section) |
| `website_index_document` | `string` | `"index.html"` | Index document for website hosting |
| `cors_allowed_origins` | `list(string)` | `[]` | Origins for CORS rules; empty disables CORS |
| `log_bucket_id` | `string` | `null` | ID of an existing bucket to receive access logs |
| `force_destroy` | `bool` | `false` | Allow deletion of non-empty bucket |

## Outputs

| Name | Description |
|------|-------------|
| `bucket_id` | Name (ID) of the S3 bucket |
| `bucket_arn` | ARN of the S3 bucket |
| `bucket_regional_domain_name` | Regional domain name of the S3 bucket |

## Bucket naming

Buckets are named `{project}-{environment}-{bucket_name_suffix}-{account_id}`.
The account ID suffix ensures global uniqueness across environments and
accounts without caller-managed random suffixes.

## Enforced security controls

These settings are always applied and cannot be overridden by module callers:

- **SSE-S3 encryption** (`AES256`) via `aws_s3_bucket_server_side_encryption_configuration`
- **Public access block** — `block_public_acls` and `ignore_public_acls` are
  always `true`; `block_public_policy` and `restrict_public_buckets` are `true`
  unless `enable_website = true` (see below)
- **Tags** — `Project`, `Environment`, and `ManagedBy = "terraform"` are always set

## Security tradeoff: `enable_website = true`

When `enable_website = true` the module sets `block_public_policy = false` and
`restrict_public_buckets = false` so a public bucket policy can be attached for
static-site delivery. `block_public_acls` and `ignore_public_acls` remain `true`
because ACL-based public access is legacy and not required for website hosting.

**This module does not manage `aws_s3_account_public_access_block`.** The
account-level block is a separate, account-wide setting that would conflict if
two modules each tried to own it. You should manage it once in a shared
infrastructure root:

```hcl
resource "aws_s3_account_public_access_block" "default" {
  block_public_acls       = true
  block_public_policy     = true   # account-wide default; per-bucket overrides still apply
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

The bucket-level block set by this module is evaluated independently of the
account-level block — the more restrictive of the two always wins.

## CORS behaviour

When `cors_allowed_origins` is non-empty, a single CORS rule is created with
`allowed_methods = ["GET", "HEAD"]` and `allowed_headers = ["*"]`. If you need
write methods (POST, PUT, DELETE) add them by extending the module or open an
issue.
