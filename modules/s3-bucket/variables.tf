variable "bucket_name_suffix" {
  description = "Short suffix appended after project and environment in the bucket name"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.bucket_name_suffix))
    error_message = "bucket_name_suffix must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name used in the bucket name and tags"
  type        = string
}

variable "enable_versioning" {
  description = "Enable S3 versioning on the bucket"
  type        = bool
  default     = true
}

variable "enable_website" {
  description = "Enable static website hosting. See the security tradeoffs section of the README before setting this to true."
  type        = bool
  default     = false
}

variable "website_index_document" {
  description = "Index document for the static website (only used when enable_website = true)"
  type        = string
  default     = "index.html"
}

variable "cors_allowed_origins" {
  description = "List of origins allowed via CORS. When non-empty, a CORS rule is created allowing GET and HEAD from these origins."
  type        = list(string)
  default     = []
}

variable "log_bucket_id" {
  description = "ID of an existing S3 bucket to receive access logs. Omit or set to null to disable access logging."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket even if it contains objects"
  type        = bool
  default     = false
}
