variable "prefix" {
  type        = string
  description = "Name prefix for all resources"
}

variable "resource_group_name" {
  type        = string
  description = "The resource group that holds the deployment"
}

variable "location" {
  type        = string
  description = "The Azure region for all resources"
}

variable "storage_account_name" {
  type        = string
  description = "Globally-unique Azure Storage account name backing object storage (3-24 lowercase alphanumeric characters)"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase alphanumeric characters (Azure Storage account naming rules)."
  }
}

variable "acr_name" {
  type        = string
  description = "Globally-unique Azure Container Registry name (5-50 alphanumeric characters)"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "acr_name must be 5-50 alphanumeric characters (Azure Container Registry naming rules)."
  }
}

variable "key_vault_name" {
  type        = string
  description = "Globally-unique Key Vault name (3-24 alphanumeric/hyphen, must start with a letter). Defaults to a name derived from the storage account name when empty."
  default     = ""
}

variable "tenant_id" {
  type        = string
  description = "The Azure AD tenant id"
}

variable "deployer_object_id" {
  type        = string
  description = "Object id of the principal running terraform, granted Key Vault Secrets Officer so it can seed secrets"
}

variable "postgres_connection_string" {
  type        = string
  description = "Postgres DSN (Azure Database for PostgreSQL Flexible Server). Seeded into Key Vault; may be left as a placeholder and edited out of band."
  default     = " "
  sensitive   = true
}

variable "acr_sku" {
  type        = string
  description = "The SKU of the Azure Container Registry"
  default     = "Premium"
}

variable "storage_account_replication_type" {
  type        = string
  description = "The replication type for the Storage account (LRS, ZRS, GRS, ...)"
  default     = "LRS"
}

variable "soft_delete_retention_days" {
  type        = number
  description = "Blob soft-delete retention (days) for the object-storage account"
  default     = 10
}

variable "key_vault_soft_delete_retention_days" {
  type        = number
  description = "Key Vault soft-delete retention (days)"
  default     = 7
}

variable "key_vault_purge_protection_enabled" {
  type        = bool
  description = "Enable Key Vault purge protection"
  default     = false
}

variable "remote_repository_enabled" {
  type        = bool
  description = "Set to true to create a DockerHub pull-through cache rule on the ACR"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags to attach to resources created by this module"
  default = {
    app       = "e2b"
    terraform = "true"
  }
}

