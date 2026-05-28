# Contributing

## Workflow: PR → Plan → Review → Merge → Apply

All changes follow this path without exception — no direct commits to `main`, no manual `terraform apply` outside CI.

```
feature branch  ──►  pull request  ──►  review  ──►  merge to main  ──►  CI applies to prod
                           │
                     CI plans + posts
                     plan as PR comment
```

### 1. Create a feature branch

Branch from `main`:

```bash
git checkout main && git pull
git checkout -b feat/your-change
```

Use a descriptive branch name (`feat/`, `fix/`, `refactor/`, `docs/`). Branch names determine CI concurrency groups — one plan per branch at a time.

### 2. Make your changes

- Terraform changes go in `modules/`, `environments/dev/`, `environments/prod/`, or `bootstrap/`.
- Lambda source changes go in `src/functions/`.
- Run `terraform fmt -recursive` before committing to pass the fmt check in CI.
- If you add a module input or output, update the Module Reference table in [README.md](README.md).

### 3. Open a pull request against `main`

When you push and open a PR, `terraform-plan.yml` triggers automatically and runs:

1. **Lint** — `terraform fmt -check -recursive` (fails fast on formatting)
2. **Security scan** — tfsec and Checkov; findings are posted as annotations
3. **Plan (dev)** — full `terraform plan` against the dev environment; output is posted as a PR comment

The plan comment is the artifact that reviewers assess. Do not merge until the plan is posted and reviewed.

### 4. Review

Every PR requires at least one approving review. Reviewers should check:

- The plan diff matches the intent of the PR description — no unexpected resource replacements or deletions.
- Sensitive values are not printed in plan output (use `sensitive = true` on outputs that contain secrets).
- New resources follow the existing naming convention (`${var.project}-${var.environment}-<suffix>`).
- IAM policies follow least privilege — no `"*"` actions or resources without justification.
- Any new CloudWatch log groups have explicit `retention_in_days` set.

If the plan shows a resource will be **replaced** (`-/+`) or **destroyed** (`-`) unexpectedly, treat it as a blocking finding and ask the author to confirm intent in the PR description.

### 5. Merge

Squash-merge or merge-commit are both acceptable. The PR title becomes the commit message on `main`; write it as an imperative sentence (`Add TTL to analytics table`, not `Added TTL` or `Adding TTL`).

### 6. Apply (automated)

Merging to `main` triggers `terraform-apply.yml`, which:

1. Requires manual approval in the GitHub **production** environment (a repository owner must click Approve in the Actions UI).
2. Runs `terraform plan` again against prod to confirm the state has not drifted since the PR plan.
3. Runs `terraform apply -auto-approve` with the prod plan file.
4. Posts CloudFront domain, distribution ID, and API Gateway URL to the workflow summary.

Only one apply can run at a time (`concurrency: group: terraform-apply`). If a second merge lands while an apply is in progress it will queue, not cancel.

## What not to do

- Do not run `terraform apply` locally against `dev` or `prod` — state will drift from what CI expects.
- Do not store secrets in `terraform.tfvars` files — use `secrets.auto.tfvars` (gitignored) and pass values via environment variables or AWS SSM Parameter Store.
- Do not add `.terraform.lock.hcl` to `.gitignore` — lock files pin provider versions and belong in version control.
- Do not skip the security scan (`tfsec`, `Checkov`) by editing workflow files without a matching PR comment explaining the exception.

## Local development

```bash
# Format all Terraform files
terraform fmt -recursive

# Validate a module
cd environments/dev
terraform init
terraform validate

# Run a plan locally (reads AWS credentials from environment)
terraform plan
```

Lambda functions can be tested locally with the AWS SAM CLI or by invoking them directly:

```bash
cd src/functions/shorten
python -c "
import json, index
event = {'body': json.dumps({'url': 'https://example.com', 'owner_id': 'test'})}
print(index.handler(event, None))
"
```
