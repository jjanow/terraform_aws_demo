output "state_bucket_name" {
  description = "Name of the S3 bucket used for Terraform remote state"
  value       = aws_s3_bucket.state.bucket
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table used for state locking"
  value       = aws_dynamodb_table.lock.name
}

output "log_bucket_name" {
  description = "Name of the S3 bucket used for state bucket access logs"
  value       = aws_s3_bucket.log.bucket
}
