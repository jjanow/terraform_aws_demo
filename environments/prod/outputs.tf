output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name for the prod environment"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for the prod environment"
  value       = aws_cloudfront_distribution.this.id
}

output "api_gateway_url" {
  description = "API Gateway stage invoke URL"
  value       = module.api.invoke_url
}
