variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
}

variable "description" {
  description = "Description of the Lambda function"
  type        = string
}

variable "handler" {
  description = "Function entrypoint (e.g. index.handler)"
  type        = string
}

variable "runtime" {
  description = "Lambda runtime identifier"
  type        = string
  default     = "python3.12"
}

variable "source_dir" {
  description = "Path to the directory containing function source code; the module zips it"
  type        = string
}

variable "environment_variables" {
  description = "Environment variables to set on the function (POWERTOOLS_LOG_LEVEL=INFO is always set and may be overridden)"
  type        = map(string)
  default     = {}
}

variable "memory_size" {
  description = "Amount of memory (MB) to allocate to the function; 128 MB maximises free-tier seconds"
  type        = number
  default     = 128
}

variable "timeout" {
  description = "Maximum execution time in seconds"
  type        = number
  default     = 30
}

variable "additional_policy_arns" {
  description = "List of managed policy ARNs to attach to the execution role in addition to AWSLambdaBasicExecutionRole"
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "JSON string for an inline IAM policy giving the function fine-grained access; omit or set to null to skip"
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch log events"
  type        = number
  default     = 14
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name used in tags"
  type        = string
}
