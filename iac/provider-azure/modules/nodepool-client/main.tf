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

    rule {
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
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Disk controller fixup for v6 SKUs.
#
# The v6 families boot only from NVMe, and azurerm has no diskControllerType on
# azurerm_linux_virtual_machine_scale_set — it exists on azurerm_linux_virtual_machine
# but not on either scale set resource, as of provider 4.81. So terraform creates
# the scale set with the default SCSI and Azure rejects the v6 size.
#
# Setting it out of band is not a workaround around terraform so much as filling a
# gap in it: the property is absent from the schema, so terraform never reads or
# diffs it and a later plan stays clean (verified on dev — the pool disappeared
# from the plan entirely once SKU and image matched).
#
# Three constraints have to be satisfied in one call: a v5 size cannot boot NVMe,
# a v6 size cannot boot SCSI, and the image must declare DiskControllerTypes.
# Changing the controller also requires the instances to be deallocated, hence the
# stop/update/start below rather than a plain update-instances.
locals {
  needs_nvme = can(regex("_v6$", var.machine_type))
}

resource "null_resource" "nvme_disk_controller" {
  count = local.needs_nvme && var.subscription_id != "" ? 1 : 0

  triggers = {
    scale_set = azurerm_linux_virtual_machine_scale_set.client.id
    sku       = var.machine_type
    image     = var.image_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      RG="${var.resource_group_name}"
      NAME="${azurerm_linux_virtual_machine_scale_set.client.name}"
      SUB="${var.subscription_id}"

      CURRENT=$(az vmss show -g "$RG" -n "$NAME" --subscription "$SUB" \
        --query "virtualMachineProfile.storageProfile.diskControllerType" -o tsv)
      if [ "$CURRENT" = "NVMe" ]; then
        echo "$NAME already on NVMe"; exit 0
      fi

      echo "$NAME: switching disk controller to NVMe"
      az vmss update -g "$RG" -n "$NAME" --subscription "$SUB" \
        --set virtualMachineProfile.storageProfile.diskControllerType=NVMe -o none

      # Instances keep the old model until told otherwise, and the controller
      # cannot change on a running VM.
      az vmss deallocate -g "$RG" -n "$NAME" --subscription "$SUB" -o none
      az vmss update-instances -g "$RG" -n "$NAME" --instance-ids '*' --subscription "$SUB" -o none
      az vmss start -g "$RG" -n "$NAME" --subscription "$SUB" -o none
    EOT
  }
}
