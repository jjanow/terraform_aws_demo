output "api_id" {
  description = "ID of the REST API Gateway"
  value       = aws_api_gateway_rest_api.this.id
}

output "api_arn" {
  description = "ARN of the REST API Gateway"
  value       = aws_api_gateway_rest_api.this.arn
}

output "invoke_url" {
  description = "Base invocation URL for the stage (https://{id}.execute-api.{region}.amazonaws.com/{stage})"
  value       = aws_api_gateway_stage.this.invoke_url
}

output "execution_arn" {
  description = "Execution ARN of the deployed stage; use this to scope further IAM policies"
  value       = aws_api_gateway_stage.this.execution_arn
}
