terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
  }
}

locals {
  scripts_path = var.scripts_path != "" ? var.scripts_path : "${path.module}/scripts"

  min_instances = var.min_instances != null ? var.min_instances : var.cluster_size
  max_instances = var.max_instances != null ? var.max_instances : var.cluster_size

  user_data = templatefile("${local.scripts_path}/start-client.sh", {
    NODE_POOL                         = var.node_pool_name
    SERVER_SCALE_SET_NAME             = "${var.prefix}control-server"
    NODE_LABELS                       = join(",", var.node_labels)
    BASE_HUGEPAGES_PERCENTAGE         = var.base_hugepages_percentage
    SET_ORCHESTRATOR_VERSION_METADATA = var.set_orchestrator_version_metadata ? "true" : "false"

    STORAGE_ACCOUNT    = var.storage_account_name
    SETUP_CONTAINER    = var.setup_container_name
    IDENTITY_CLIENT_ID = var.identity_client_id
    KEY_VAULT_NAME     = var.key_vault_name
    JUICEFS_VOLUMES    = var.juicefs_volumes

    NOMAD_TOKEN                  = var.nomad_acl_token
    CONSUL_TOKEN                 = var.consul_acl_token
    CONSUL_GOSSIP_ENCRYPTION_KEY = var.consul_gossip_encryption_key
    CONSUL_DNS_REQUEST_TOKEN     = var.consul_dns_request_token

    ACR_LOGIN_SERVER = var.acr_login_server

    FC_ENV_PIPELINE_CONTAINER = var.fc_env_pipeline_container_name
    FC_KERNELS_CONTAINER      = var.fc_kernels_container_name
    FC_VERSIONS_CONTAINER     = var.fc_versions_container_name
    FC_BUSYBOX_CONTAINER      = var.fc_busybox_container_name

    RUN_CONSUL_FILE_HASH = var.setup_files_hash["run-consul"]
    RUN_NOMAD_FILE_HASH  = var.setup_files_hash["run-nomad"]
  })
}

# One VMSS for a client-family pool (Firecracker hosts). Instantiated twice by
# the nomad-cluster module: once as the client pool, once as the build pool.
# Mirrors provider-aws nodepool-client.
resource "azurerm_linux_virtual_machine_scale_set" "client" {
  # The v6 transition below has to complete before terraform submits a v6 SKU on
  # a scale set still carrying SCSI, which Azure rejects.
  depends_on = [null_resource.nvme_disk_controller]

  name                = "${var.prefix}${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.machine_type
  instances           = var.cluster_size

  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false

  upgrade_mode           = "Manual"
  overprovision          = false
  single_placement_group = false

  source_image_id = var.image_id != "" ? var.image_id : null
  dynamic "source_image_reference" {
    for_each = var.image_id == "" ? [1] : []
    content {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts-gen2"
      version   = "latest"
    }
  }

  custom_data = base64encode(local.user_data)

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
    disk_size_gb         = var.os_disk_size_gb
  }

  network_interface {
    name    = "${var.prefix}${var.name}-nic"
    primary = true

    ip_configuration {
      name                                         = "primary"
      primary                                      = true
      subnet_id                                    = var.subnet_id
      application_gateway_backend_address_pool_ids = var.appgw_backend_pool_ids
    }
  }

  tags = merge(var.tags, {
    Name                   = "${var.prefix}${var.name}"
    (var.cluster_tag_name) = var.cluster_tag_value
  })

  lifecycle {
    ignore_changes = [instances]
  }
}

# CPU + (opt-in) memory autoscale, mirroring the GCP MIG autoscaler (CPU
# utilization + memory percent). Defaults to a no-op band (min == max ==
# cluster_size); raise max_instances to enable scale-out. Memory uses the
# "Available Memory Bytes" platform metric (no guest agent on v5 SKUs);
# thresholds are absolute bytes so they are per-pool opt-in.
# Scale-out fires when ANY rule matches; scale-in requires ALL Decrease
# rules to match (Azure autoscale semantics) — the memory Decrease rule
# therefore makes scale-in stricter, not looser. NOTE: scale-in reimages a
# node that may be running sandboxes; acceptable for dev cost-control, use
# GCP-style scale-out-only (drop the Decrease rules) for prod.
resource "azurerm_monitor_autoscale_setting" "client" {
  name                = "${var.prefix}${var.name}-autoscale"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.client.id

  profile {
    name = "cpu"

    capacity {
      default = var.cluster_size
      minimum = local.min_instances
      maximum = local.max_instances
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.client.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.scale_out_cpu_threshold
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    dynamic "rule" {
      for_each = var.scale_in_cpu_threshold != null ? [1] : []
      content {
        metric_trigger {
          metric_name        = "Percentage CPU"
          metric_resource_id = azurerm_linux_virtual_machine_scale_set.client.id
          time_grain         = "PT1M"
          statistic          = "Average"
          time_window        = "PT5M"
          time_aggregation   = "Average"
          operator           = "LessThan"
          threshold          = var.scale_in_cpu_threshold
        }

        scale_action {
          direction = "Decrease"
          type      = "ChangeCount"
          value     = "1"
          cooldown  = "PT10M"
        }
      }
    }

    dynamic "rule" {
      for_each = var.scale_out_memory_free_bytes != null ? [1] : []
      content {
        metric_trigger {
          metric_name        = "Available Memory Bytes"
          metric_resource_id = azurerm_linux_virtual_machine_scale_set.client.id
          time_grain         = "PT1M"
          statistic          = "Average"
          time_window        = "PT5M"
          time_aggregation   = "Average"
          operator           = "LessThan"
          threshold          = var.scale_out_memory_free_bytes
        }

        scale_action {
          direction = "Increase"
          type      = "ChangeCount"
          value     = "1"
          cooldown  = "PT5M"
        }
      }
    }

    dynamic "rule" {
      for_each = var.scale_in_memory_free_bytes != null ? [1] : []
      content {
        metric_trigger {
          metric_name        = "Available Memory Bytes"
          metric_resource_id = azurerm_linux_virtual_machine_scale_set.client.id
          time_grain         = "PT1M"
          statistic          = "Average"
          time_window        = "PT5M"
          time_aggregation   = "Average"
          operator           = "GreaterThan"
          threshold          = var.scale_in_memory_free_bytes
        }

        scale_action {
          direction = "Decrease"
          type      = "ChangeCount"
          value     = "1"
          cooldown  = "PT10M"
        }
      }
    }

    # The rule that actually fires. Percentage CPU and Available Memory Bytes
    # cannot observe either limit that binds on a client node:
    #
    #   * max-sandboxes-per-node is a count. No host metric moves with it.
    #   * Sandbox memory is served from a hugepage pool preallocated at boot, so
    #     handing pages to sandboxes never changes Available Memory Bytes. A node
    #     can be at its memory ceiling while reporting ~half its RAM free.
    #   * CPU is oversubscribed and sandboxes are mostly idle, so utilisation
    #     sits near single digits at full occupancy.
    #
    # Measured: a node saturated at 200 sandboxes sat at 3.6% average CPU with
    # 117 GiB "available", and the pool never scaled while placement failed.
    #
    # slots-metrics-publisher (see nomad/jobs) computes utilisation against both
    # limits and publishes the higher of the two here. Threshold is deliberately
    # well under 100: a scale-out takes minutes (evaluation window, cooldown, VM
    # boot) while a sandbox create takes ~1s, so waiting for saturation means
    # rejecting work for the whole gap.
    dynamic "rule" {
      for_each = var.scale_out_slots_used_percentage != null ? [1] : []
      content {
        metric_trigger {
          metric_name        = "SlotsUsedPct"
          metric_namespace   = "e2b"
          metric_resource_id = azurerm_linux_virtual_machine_scale_set.client.id
          time_grain         = "PT1M"
          statistic          = "Average"
          time_window        = "PT5M"
          time_aggregation   = "Average"
          operator           = "GreaterThan"
          threshold          = var.scale_out_slots_used_percentage
        }

        scale_action {
          direction = "Increase"
          type      = "ChangeCount"
          value     = "1"
          cooldown  = "PT5M"
        }
      }
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# v5 -> v6 disk controller transition.
#
# The v6 families boot only from NVMe. Creating a v6 pool from scratch is fine —
# Azure picks NVMe on its own once the image declares DiskControllerTypes, which
# is verified. The problem is moving an existing pool: it already carries SCSI,
# and azurerm has no diskControllerType on either scale set resource as of
# provider 4.81 (azurerm_linux_virtual_machine has it; the scale sets do not).
# terraform therefore submits a v6 SKU alongside the inherited SCSI and Azure
# rejects the update.
#
# Three properties constrain each other and have to move in one request: a v5
# size cannot boot NVMe, a v6 size cannot boot SCSI, and the image must declare
# support. So this does the whole transition itself, before terraform touches the
# scale set — hence the depends_on above and the deliberate absence of any
# reference to the scale set resource here, which would otherwise order it after.
#
# It is a no-op in every case except the one it exists for: a scale set that does
# not exist yet (fresh create, which needs no help) or one already on NVMe.
#
# Not a workaround around terraform: the property is absent from the schema, so
# terraform neither reads nor diffs it, and once SKU and image agree the pool
# drops out of the plan entirely. Replace this with the native attribute when
# azurerm grows one.
locals {
  needs_nvme = can(regex("_v6$", var.machine_type))
  pool_name  = "${var.prefix}${var.name}"
}

resource "null_resource" "nvme_disk_controller" {
  count = local.needs_nvme && var.subscription_id != "" ? 1 : 0

  triggers = {
    pool  = local.pool_name
    sku   = var.machine_type
    image = var.image_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      RG="${var.resource_group_name}"
      NAME="${local.pool_name}"
      SUB="${var.subscription_id}"
      SKU="${var.machine_type}"
      IMG="${var.image_id}"

      if ! az vmss show -g "$RG" -n "$NAME" --subscription "$SUB" -o none 2>/dev/null; then
        echo "$NAME does not exist yet; a fresh v6 create picks NVMe on its own"
        exit 0
      fi

      CURRENT=$(az vmss show -g "$RG" -n "$NAME" --subscription "$SUB"         --query "virtualMachineProfile.storageProfile.diskControllerType" -o tsv)
      if [ "$CURRENT" = "NVMe" ]; then
        echo "$NAME already on NVMe"
        exit 0
      fi

      echo "$NAME: $CURRENT -> NVMe, moving SKU and image in the same request"
      SET_ARGS="sku.name=$SKU virtualMachineProfile.storageProfile.diskControllerType=NVMe"
      if [ -n "$IMG" ]; then
        SET_ARGS="$SET_ARGS virtualMachineProfile.storageProfile.imageReference.id=$IMG"
      fi
      az vmss update -g "$RG" -n "$NAME" --subscription "$SUB" --set $SET_ARGS -o none

      # The controller cannot change on a running VM, and Manual-mode instances
      # keep the old model until told otherwise.
      az vmss deallocate -g "$RG" -n "$NAME" --subscription "$SUB" -o none
      az vmss update-instances -g "$RG" -n "$NAME" --instance-ids '*' --subscription "$SUB" -o none
      az vmss start -g "$RG" -n "$NAME" --subscription "$SUB" -o none
    EOT
  }
}
