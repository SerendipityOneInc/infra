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

  user_data = templatefile("${local.scripts_path}/start-clickhouse.sh", {
    NODE_POOL                    = var.node_pool_name
    SERVER_SCALE_SET_NAME        = "${var.prefix}control-server"
    STORAGE_ACCOUNT              = var.storage_account_name
    SETUP_CONTAINER              = var.setup_container_name
    IDENTITY_CLIENT_ID           = var.identity_client_id
    CONSUL_TOKEN                 = var.consul_acl_token
    CONSUL_GOSSIP_ENCRYPTION_KEY = var.consul_gossip_encryption_key
    CONSUL_DNS_REQUEST_TOKEN     = var.consul_dns_request_token

    ACR_LOGIN_SERVER = var.acr_login_server

    RUN_CONSUL_FILE_HASH = var.setup_files_hash["run-consul"]
    RUN_NOMAD_FILE_HASH  = var.setup_files_hash["run-nomad"]
  })
}

# One VMSS for the ClickHouse node pool with a persistent managed data disk per
# instance. Mirrors provider-aws nodepool-clickhouse (which uses standalone
# instances + attached EBS to keep data across replacement).
#
# TODO(azure-clickhouse): VMSS-managed data disks persist across reboot/reimage
# but are deleted on scale-in. AWS deliberately avoids the ASG for this reason.
# For clickhouse_cluster_size > 1 the single job-constraint tag below is also
# insufficient (AWS tags each instance distinctly). Revisit if HA ClickHouse is
# needed; today cluster_size is 1.
resource "azurerm_linux_virtual_machine_scale_set" "clickhouse" {
  name                = "${var.prefix}clickhouse"
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

  # Persistent data disk, surfaced in the VM at /dev/disk/azure/scsi1/lun0.
  data_disk {
    lun                  = 0
    caching              = "None"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.data_disk_size_gb
  }

  network_interface {
    name    = "${var.prefix}clickhouse-nic"
    primary = true

    ip_configuration {
      name      = "primary"
      primary   = true
      subnet_id = var.subnet_id
    }
  }

  tags = merge(var.tags, {
    Name                   = "${var.prefix}orch-clickhouse"
    (var.cluster_tag_name) = var.cluster_tag_value
    # Pins ClickHouse Nomad jobs to these nodes (read at boot via Azure IMDS).
    job-constraint = "${var.job_constraint_prefix}-1"
  })

  lifecycle {
    ignore_changes = [instances]
  }
}
