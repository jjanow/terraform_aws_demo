variable "function_names" {
  description = "Names of the Lambda functions to monitor"
  type        = list(string)
}

variable "api_gateway_name" {
  description = "Name of the API Gateway REST API to monitor"
  type        = string
}

variable "dynamodb_table_names" {
  description = "Names of DynamoDB tables to include in dashboard capacity widgets; not in the original spec but required for the DynamoDB dashboard row"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "Email address subscribed to the SNS alarm topic"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name used in resource names and tags"
  type        = string
}
