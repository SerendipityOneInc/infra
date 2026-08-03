terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

locals {
  setup_files = {
    "scripts/run-consul.sh" = "run-consul",
    "scripts/run-nomad.sh"  = "run-nomad"
  }

  setup_files_hash = {
    "run-consul" = substr(filesha256("${path.module}/scripts/run-consul.sh"), 0, 5)
    "run-nomad"  = substr(filesha256("${path.module}/scripts/run-nomad.sh"), 0, 5)
  }

  # Tag the Consul Azure cloud auto-join looks for to discover cluster members.
  cluster_tag_name  = "cluster-discovery-name"
  cluster_tag_value = "${var.prefix}nomad-cluster"
}

# Admin password for the VMSS instances. SSH is denied from the internet by the
# cluster NSG and nodes have no public IP (NAT egress only).
# TODO(azure-hardening): move to admin_ssh_key.
resource "random_password" "vm_admin" {
  length           = 24
  special          = true
  override_special = "!#%*()-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# Upload the Consul/Nomad runner scripts to the setup Blob container. Nodes pull
# them at boot via the Managed Identity (replaces the AWS aws_s3_object + s3 cp).
resource "azurerm_storage_blob" "setup_config" {
  for_each = local.setup_files

  name                   = "${each.value}-${local.setup_files_hash[each.value]}.sh"
  storage_account_name   = var.storage_account_name
  storage_container_name = var.setup_container_name
  type                   = "Block"
  source                 = "${path.module}/${each.key}"
}

# ---
# Nodepool modules
# ---

module "control_server" {
  source = "../modules/nodepool-control-server"

  prefix              = var.prefix
  resource_group_name = var.resource_group_name
  location            = var.location

  identity_id        = var.identity_id
  identity_client_id = var.identity_client_id
  subnet_id          = var.cluster_subnet_id

  cluster_tag_name  = local.cluster_tag_name
  cluster_tag_value = local.cluster_tag_value

  storage_account_name = var.storage_account_name
  setup_container_name = var.setup_container_name
  setup_files_hash     = local.setup_files_hash

  image_id               = var.control_server_image_id
  cluster_size           = var.control_server_cluster_size
  machine_type           = var.control_server_machine_type
  appgw_backend_pool_ids = var.server_appgw_backend_pool_ids

  admin_username = var.admin_username
  admin_password = random_password.vm_admin.result

  nomad_acl_token              = var.nomad_acl_token_secret
  consul_acl_token             = var.consul_acl_token_secret
  consul_gossip_encryption_key = var.consul_gossip_encryption_key

  tags = var.tags
}

module "api" {
  source = "../modules/nodepool-api"

  prefix              = var.prefix
  resource_group_name = var.resource_group_name
  location            = var.location

  identity_id            = var.identity_id
  identity_client_id     = var.identity_client_id
  subnet_id              = var.cluster_subnet_id
  appgw_backend_pool_ids = var.api_appgw_backend_pool_ids
  lb_backend_pool_ids    = var.api_lb_backend_pool_ids

  cluster_tag_name  = local.cluster_tag_name
  cluster_tag_value = local.cluster_tag_value

  storage_account_name = var.storage_account_name
  setup_container_name = var.setup_container_name
  setup_files_hash     = local.setup_files_hash

  image_id     = var.api_image_id
  cluster_size = var.api_cluster_size
  machine_type = var.api_machine_type

  admin_username = var.admin_username
  admin_password = random_password.vm_admin.result

  node_pool_name               = var.api_node_pool_name
  consul_acl_token             = var.consul_acl_token_secret
  consul_gossip_encryption_key = var.consul_gossip_encryption_key
  consul_dns_request_token     = var.consul_dns_request_token_secret

  acr_login_server = var.acr_login_server

  tags = var.tags
}

module "clickhouse" {
  source = "../modules/nodepool-clickhouse"

  prefix              = var.prefix
  resource_group_name = var.resource_group_name
  location            = var.location

  identity_id        = var.identity_id
  identity_client_id = var.identity_client_id
  subnet_id          = var.cluster_subnet_id

  cluster_tag_name  = local.cluster_tag_name
  cluster_tag_value = local.cluster_tag_value

  storage_account_name = var.storage_account_name
  setup_container_name = var.setup_container_name
  setup_files_hash     = local.setup_files_hash

  image_id     = var.clickhouse_image_id
  cluster_size = var.clickhouse_cluster_size
  machine_type = var.clickhouse_machine_type

  admin_username = var.admin_username
  admin_password = random_password.vm_admin.result

  node_pool_name               = var.clickhouse_node_pool_name
  job_constraint_prefix        = var.clickhouse_job_constraint_prefix
  consul_acl_token             = var.consul_acl_token_secret
  consul_gossip_encryption_key = var.consul_gossip_encryption_key
  consul_dns_request_token     = var.consul_dns_request_token_secret

  acr_login_server = var.acr_login_server

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Proximity placement group for the Firecracker pools (build + client).
#
# Azure guarantees a SKU's vCPU and memory, not the CPU model behind it. On
# staging two E32ads_v5 instances of the same scale set came up as EPYC 9V74
# (Genoa) and EPYC 7763 (Milan), one per fault domain, and rebuilding the second
# reproduced Milan rather than shuffling it.
#
# That matters because e2b filters placement on CPU model. A template records the
# CPU it was built on, and machineinfo.IsCompatibleWith only permits a different
# model when the pair is in a hardcoded whitelist that today lists Intel Ice Lake
# -> Emerald Rapids and nothing else. On AMD it reduces to exact equality, so the
# mismatched node received zero sandboxes ever while still being billed, and the
# cluster topped out at one node's 200-sandbox cap.
#
# Build and client share the group deliberately: a template built on one
# generation is unplaceable on the other, so the two pools have to agree.
#
# allowed_vm_sizes is the intent — Azure picks a cluster that can serve every
# size listed, instead of discovering at scale-out time that it cannot.
resource "azurerm_proximity_placement_group" "firecracker" {
  count               = var.enable_firecracker_ppg ? 1 : 0
  name                = "${var.prefix}firecracker-ppg"
  resource_group_name = var.resource_group_name
  location            = var.location

  allowed_vm_sizes = distinct([var.client_machine_type, var.build_machine_type])

  # zone is deliberately unset: pinning the group to one availability zone would
  # force both scale sets into it too, trading zone redundancy for a guarantee
  # the group already provides by co-locating on one cluster.
  tags = var.tags
}

module "build" {
  source = "../modules/nodepool-client"

  proximity_placement_group_id = var.enable_firecracker_ppg ? azurerm_proximity_placement_group.firecracker[0].id : ""
  subscription_id              = var.subscription_id

  name                = "orch-build"
  prefix              = var.prefix
  resource_group_name = var.resource_group_name
  location            = var.location

  identity_id        = var.identity_id
  identity_client_id = var.identity_client_id
  subnet_id          = var.cluster_subnet_id

  cluster_tag_name  = local.cluster_tag_name
  cluster_tag_value = local.cluster_tag_value

  storage_account_name = var.storage_account_name
  setup_container_name = var.setup_container_name
  setup_files_hash     = local.setup_files_hash

  image_id      = var.build_image_id
  cluster_size  = var.build_cluster_size
  machine_type  = var.build_machine_type
  max_instances = var.build_max_instances

  # Template builds never touch hugepages (memfd/uffd restores use normal
  # pages; observed HugePages_Free == Total after days of builds), while the
  # module default (60%) locked ~16G of the 32G node away from them — the
  # direct cause of random "mmap memfd: cannot allocate memory" build
  # failures. Sandboxes (which DO use hugepages) run on the client pool only.
  base_hugepages_percentage = 0

  admin_username = var.admin_username
  admin_password = random_password.vm_admin.result

  node_pool_name        = var.build_node_pool_name
  node_labels           = var.build_node_labels
  nested_virtualization = var.build_server_nested_virtualization

  nomad_acl_token              = var.nomad_acl_token_secret
  consul_acl_token             = var.consul_acl_token_secret
  consul_gossip_encryption_key = var.consul_gossip_encryption_key
  consul_dns_request_token     = var.consul_dns_request_token_secret

  acr_login_server = var.acr_login_server
  key_vault_name   = var.key_vault_name
  juicefs_volumes  = var.juicefs_volumes

  fc_env_pipeline_container_name = var.fc_env_pipeline_container_name
  fc_kernels_container_name      = var.fc_kernels_container_name
  fc_versions_container_name     = var.fc_versions_container_name
  fc_busybox_container_name      = var.fc_busybox_container_name

  tags = var.tags
}

module "client" {
  source = "../modules/nodepool-client"

  proximity_placement_group_id = var.enable_firecracker_ppg ? azurerm_proximity_placement_group.firecracker[0].id : ""
  subscription_id              = var.subscription_id

  name                = "orch-client"
  prefix              = var.prefix
  resource_group_name = var.resource_group_name
  location            = var.location

  identity_id            = var.identity_id
  identity_client_id     = var.identity_client_id
  subnet_id              = var.cluster_subnet_id
  appgw_backend_pool_ids = var.client_appgw_backend_pool_ids

  cluster_tag_name  = local.cluster_tag_name
  cluster_tag_value = local.cluster_tag_value

  storage_account_name = var.storage_account_name
  setup_container_name = var.setup_container_name
  setup_files_hash     = local.setup_files_hash

  image_id                  = var.client_image_id
  cluster_size              = var.client_cluster_size
  machine_type              = var.client_machine_type
  max_instances             = var.client_max_instances
  base_hugepages_percentage = var.client_base_hugepages_percentage

  scale_out_memory_free_bytes = var.client_scale_out_memory_free_bytes
  scale_in_memory_free_bytes  = var.client_scale_in_memory_free_bytes

  admin_username = var.admin_username
  admin_password = random_password.vm_admin.result

  node_pool_name        = var.client_node_pool_name
  node_labels           = var.client_node_labels
  nested_virtualization = var.client_server_nested_virtualization

  nomad_acl_token              = var.nomad_acl_token_secret
  consul_acl_token             = var.consul_acl_token_secret
  consul_gossip_encryption_key = var.consul_gossip_encryption_key
  consul_dns_request_token     = var.consul_dns_request_token_secret

  acr_login_server = var.acr_login_server
  key_vault_name   = var.key_vault_name
  juicefs_volumes  = var.juicefs_volumes

  fc_env_pipeline_container_name = var.fc_env_pipeline_container_name
  fc_kernels_container_name      = var.fc_kernels_container_name
  fc_versions_container_name     = var.fc_versions_container_name
  fc_busybox_container_name      = var.fc_busybox_container_name

  tags = var.tags
}
