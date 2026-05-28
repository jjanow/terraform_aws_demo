locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # DynamoDB requires every key attribute (table + GSI) to be declared exactly
  # once in the `attribute` block. Build a deduplicated map by merging GSI keys
  # first (defaulting to "S") then primary keys last so explicit types win.
  all_attributes = merge(
    { for gsi in var.global_secondary_indexes : gsi.hash_key => "S" },
    { for gsi in var.global_secondary_indexes : gsi.range_key => "S" if gsi.range_key != null },
    var.range_key != null ? { (var.range_key) = var.range_key_type } : {},
    { (var.hash_key) = var.hash_key_type },
  )
}

resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = var.hash_key
  range_key = var.range_key

  # Prevent accidental deletion in production.
  deletion_protection_enabled = var.environment == "prod"

  dynamic "attribute" {
    for_each = local.all_attributes
    content {
      name = attribute.key
      type = attribute.value
    }
  }

  dynamic "ttl" {
    for_each = var.ttl_attribute != null ? [var.ttl_attribute] : []
    content {
      attribute_name = ttl.value
      enabled        = true
    }
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    # enabled = false → AWS owned key (free, the DynamoDB default).
    # Set enabled = true and provide kms_key_arn to use a customer-managed key.
    enabled = false
  }

  dynamic "global_secondary_index" {
    for_each = var.global_secondary_indexes
    content {
      name            = global_secondary_index.value.name
      hash_key        = global_secondary_index.value.hash_key
      range_key       = global_secondary_index.value.range_key
      projection_type = global_secondary_index.value.projection_type
    }
  }

  tags = local.tags
}
