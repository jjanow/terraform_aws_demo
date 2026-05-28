locals {
  prefix = "${var.project_name}-bootstrap"

  common_tags = {
    Project     = var.project_name
    Environment = "bootstrap"
    ManagedBy   = "terraform"
  }
}
