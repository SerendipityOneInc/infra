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

# CPU-based autoscale, mirroring the AWS ASG target-tracking. Defaults to a
# no-op band (min == max == cluster_size); raise max_instances to enable
# scale-out. TODO(azure-autoscale): guest memory metrics require the Azure
# Monitor agent / diagnostics extension, so only host CPU is used here.
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
  }

  tags = var.tags
}
