output "function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.this.arn
}

output "function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.this.function_name
}

output "invoke_arn" {
  description = "ARN used to invoke the function (e.g. from API Gateway)"
  value       = aws_lambda_function.this.invoke_arn
}

output "role_arn" {
  description = "ARN of the Lambda execution IAM role"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the Lambda execution IAM role"
  value       = aws_iam_role.this.name
}
