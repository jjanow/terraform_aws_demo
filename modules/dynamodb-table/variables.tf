variable "table_name" {
  description = "Name of the DynamoDB table"
  type        = string
}

variable "hash_key" {
  description = "Attribute name to use as the hash (partition) key"
  type        = string
}

variable "hash_key_type" {
  description = "Type of the hash key attribute: S (string), N (number), or B (binary)"
  type        = string
  default     = "S"

  validation {
    condition     = contains(["S", "N", "B"], var.hash_key_type)
    error_message = "hash_key_type must be S, N, or B."
  }
}

variable "range_key" {
  description = "Attribute name to use as the range (sort) key; omit to create a partition-key-only table"
  type        = string
  default     = null
}

variable "range_key_type" {
  description = "Type of the range key attribute: S (string), N (number), or B (binary)"
  type        = string
  default     = "S"

  validation {
    condition     = contains(["S", "N", "B"], var.range_key_type)
    error_message = "range_key_type must be S, N, or B."
  }
}

variable "ttl_attribute" {
  description = "Name of the attribute used for TTL-based item expiry; omit to disable TTL"
  type        = string
  default     = null
}

variable "global_secondary_indexes" {
  description = "GSIs to create. GSI key attributes are assumed to be type S (string); extend if needed."
  type = list(object({
    name            = string
    hash_key        = string
    range_key       = optional(string)
    projection_type = string
  }))
  default = []
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name used in tags"
  type        = string
}
