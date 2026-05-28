variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resource names"
  type        = string

  validation {
    condition     = length(var.project_name) <= 34
    error_message = "project_name must be 34 characters or fewer so bucket names stay within the 63-character S3 limit."
  }
}

variable "github_org" {
  description = "GitHub organization or username that owns the repository (used to scope the OIDC trust policy)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (used to scope the OIDC trust policy)"
  type        = string
}
