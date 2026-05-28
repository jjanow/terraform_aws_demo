variable "api_name" {
  description = "Name of the REST API Gateway"
  type        = string
}

variable "description" {
  description = "Description of the REST API Gateway"
  type        = string
}

variable "stage_name" {
  description = "Name of the deployment stage (e.g. v1, dev)"
  type        = string
}

variable "burst_limit" {
  description = "Maximum number of requests API Gateway allows in a burst"
  type        = number
  default     = 100
}

variable "rate_limit" {
  description = "Steady-state requests per second allowed by API Gateway"
  type        = number
  default     = 50
}

variable "lambda_integrations" {
  description = "Lambda integrations to wire into the API; each entry maps one HTTP method + resource path to a Lambda function"
  type = list(object({
    http_method          = string
    resource_path        = string
    lambda_invoke_arn    = string
    lambda_function_name = string
    request_schema_json  = optional(string)
  }))

  validation {
    condition = alltrue([
      for i in var.lambda_integrations :
      can(regex("^/[a-zA-Z0-9_{}-]+(/[a-zA-Z0-9_{}-]+)?$", i.resource_path))
    ])
    error_message = "Each resource_path must start with '/' and contain at most two path segments (e.g. /items or /items/{id}). Deeper nesting is not supported."
  }

  validation {
    condition = length(var.lambda_integrations) == length(toset([
      for i in var.lambda_integrations : "${i.http_method} ${i.resource_path}"
    ]))
    error_message = "Each http_method + resource_path combination must be unique across lambda_integrations."
  }
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name used in tags"
  type        = string
}
