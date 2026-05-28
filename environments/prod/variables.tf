variable "project" {
  description = "Project name used in resource names and tags"
  type        = string
}

variable "alert_email" {
  description = "Email address subscribed to the CloudWatch alarm SNS topic"
  type        = string
}
