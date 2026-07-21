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

  user_data = templatefile("${local.scripts_path}/start-server.sh", {
    NUM_SERVERS                  = var.cluster_size
    SERVER_SCALE_SET_NAME        = "${var.prefix}control-server"
    STORAGE_ACCOUNT              = var.storage_account_name
    SETUP_CONTAINER              = var.setup_container_name
    IDENTITY_CLIENT_ID           = var.identity_client_id
    NOMAD_TOKEN                  = var.nomad_acl_token
    CONSUL_TOKEN                 = var.consul_acl_token
    CONSUL_GOSSIP_ENCRYPTION_KEY = var.consul_gossip_encryption_key

    RUN_CONSUL_FILE_HASH = var.setup_files_hash["run-consul"]
    RUN_NOMAD_FILE_HASH  = var.setup_files_hash["run-nomad"]
  })
}

# One VMSS for the Nomad/Consul server pool. Mirrors provider-aws
# nodepool-control-server (launch template + ASG), Azure-ised to a VMSS.
resource "azurerm_linux_virtual_machine_scale_set" "control_server" {
  name                = "${var.prefix}control-server"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.machine_type
  instances           = var.cluster_size

  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false

  # Rolling upgrade (terraform-driven): model changes (App Gateway pool
  # membership, custom_data, image) roll onto the running instances automatically
  # on `terraform apply`, one server at a time so Nomad/Consul raft quorum is
  # preserved — no manual `az vmss update-instances` / `reimage`. App Gateway
  # does not provide a VMSS health probe, so the Application Health extension
  # below is the health source that gates the rolling batches and instance repair.
  upgrade_mode           = "Rolling"
  overprovision          = false
  single_placement_group = false

  rolling_upgrade_policy {
    # 34% of 3 instances = 1 at a time; quorum (2/3) stays up. Pause between
    # batches so the reimaged server rejoins the cluster before the next.
    max_batch_instance_percent              = 34
    max_unhealthy_instance_percent          = 100
    max_unhealthy_upgraded_instance_percent = 100
    pause_time_between_batches              = "PT2M"
  }

  # Health source for Rolling + automatic instance repair (App Gateway gives no
  # VMSS probe). Reports each instance healthy once Nomad's agent health endpoint
  # returns 2xx on the API port.
  extension {
    name                       = "AppHealth"
    publisher                  = "Microsoft.ManagedServices"
    type                       = "ApplicationHealthLinux"
    type_handler_version       = "1.0"
    auto_upgrade_minor_version = true
    settings = jsonencode({
      protocol    = "http"
      port        = var.nomad_api_port
      requestPath = "/v1/agent/health"
    })
  }

  automatic_instance_repair {
    enabled = true
  }

  # Packer image when supplied; otherwise a Gen2 Ubuntu marketplace image so the
  # module validates/bootstraps before the Packer chunk lands.
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
    name    = "${var.prefix}control-server-nic"
    primary = true

    ip_configuration {
      name                                         = "primary"
      primary                                      = true
      subnet_id                                    = var.subnet_id
      application_gateway_backend_address_pool_ids = var.appgw_backend_pool_ids
    }
  }

  tags = merge(var.tags, {
    Name = "${var.prefix}orch-server"
    # Tag to identify Nomad cluster members so Consul Azure auto-join can work.
    (var.cluster_tag_name) = var.cluster_tag_value
    # Read at boot (Azure IMDS) so Consul sets bootstrap_expect correctly.
    cluster-size = tostring(var.cluster_size)
  })

  lifecycle {
    ignore_changes = [instances]
  }
}
