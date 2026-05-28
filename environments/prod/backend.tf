terraform {
  backend "s3" {
    # Bucket created by bootstrap/; replace ACCOUNT_ID with your AWS account ID.
    # Run: terraform init -reconfigure after updating.
    bucket         = "tf-demo-bootstrap-state-ACCOUNT_ID"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-demo-bootstrap-lock"
    encrypt        = true
  }
}
