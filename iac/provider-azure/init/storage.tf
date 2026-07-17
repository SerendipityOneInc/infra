# ---
# Object storage. In GCP/AWS each bucket role is a separate bucket; on Azure they
# become Blob containers inside a single Storage account. Object storage is
# addressed by the Go orchestrator as az://<account>/<container>
# (STORAGE_PROVIDER=AzureBucket + AZURE_STORAGE_ACCOUNT).
# ---
resource "azurerm_storage_account" "storage" {
  name                          = var.storage_account_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  account_tier                  = "Standard"
  account_kind                  = "StorageV2"
  account_replication_type      = var.storage_account_replication_type
  public_network_access_enabled = true
  https_traffic_only_enabled    = true
  min_tls_version               = "TLS1_2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.soft_delete_retention_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_retention_days
    }
  }

  tags = var.tags
}

locals {
  # Blob container names must be 3-63 chars, lowercase alphanumeric and hyphens.
  # Keyed by logical bucket role -> container name (mirrors AWS/GCP buckets.tf).
  containers = {
    setup              = "instance-setup"
    fc_kernels         = "fc-kernels"
    fc_versions        = "fc-versions"
    fc_env_pipeline    = "fc-env-pipeline"
    fc_busybox         = "fc-busybox"
    fc_templates       = "fc-templates"
    fc_build_cache     = "fc-build-cache"
    loki               = "loki-storage"
    clickhouse_backups = "clickhouse-backups"
  }
}

resource "azurerm_storage_container" "containers" {
  for_each = local.containers

  name                  = each.value
  storage_account_id    = azurerm_storage_account.storage.id
  container_access_type = "private"
}

# Lifecycle management: expire Loki chunks after 8 days and ClickHouse backups
# after 30 days (mirrors the AWS lifecycle rules on those buckets).
resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.storage.id

  rule {
    name    = "expire-loki-older-than-8-days"
    enabled = true

    filters {
      prefix_match = ["${local.containers.loki}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 8
      }
    }
  }

  rule {
    name    = "expire-clickhouse-backups-older-than-30-days"
    enabled = true

    filters {
      prefix_match = ["${local.containers.clickhouse_backups}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 30
      }
    }
  }
}

