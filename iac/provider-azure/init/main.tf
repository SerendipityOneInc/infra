data "azurerm_client_config" "current" {}

locals {
  # Key Vault names are 3-24 chars, must start with a letter, and allow only
  # alphanumerics and hyphens. Derive a deterministic, globally-unique-ish name
  # from the (globally unique) storage account name unless one is supplied.
  key_vault_name = var.key_vault_name != "" ? var.key_vault_name : substr("kv-${var.storage_account_name}", 0, 24)
}

# ---
# User-assigned Managed Identity for the cluster nodes (VMSS). Mirrors the AWS
# instance IAM role: it is granted data-plane access to object storage (Blob),
# pull access to the container registry (AcrPull), and read access to secrets
# (Key Vault Secrets User).
# ---
resource "azurerm_user_assigned_identity" "infra_instances" {
  name                = "${var.prefix}infra-instances"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_role_assignment" "instances_blob_data_contributor" {
  scope                = azurerm_storage_account.storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.infra_instances.principal_id
}

# `make build-and-upload` pushes the orchestrator / template-manager / envd
# binaries into fc-env-pipeline with `az storage blob upload --auth-mode login`,
# so whoever runs it needs data-plane access: the control-plane Owner and
# Contributor roles do not grant it. Same reasoning as
# deployer_kv_secrets_officer.
resource "azurerm_role_assignment" "deployer_blob_data_contributor" {
  scope                = azurerm_storage_account.storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.deployer_object_id
}

resource "azurerm_role_assignment" "instances_acr_pull" {
  scope                = azurerm_container_registry.core.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.infra_instances.principal_id
}

resource "azurerm_role_assignment" "instances_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.infra_instances.principal_id
}

# Consul/Nomad Azure cloud auto-join enumerates the SERVER VMSS instances'
# network interfaces to discover peers (resource_group + vm_scale_set mode).
# That requires Microsoft.Compute/virtualMachineScaleSets/networkInterfaces/read,
# which the built-in Reader role grants. Scoped to the resource group, which is
# dedicated to this e2b stack. Without this the identity gets 403 AuthorizationFailed
# and Consul never forms quorum (so Nomad never starts).
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

resource "azurerm_role_assignment" "instances_reader" {
  scope                = data.azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.infra_instances.principal_id
}

# Client nodes publish a custom "sandbox slots used" metric to Azure Monitor
# against their own VMSS resource, so autoscale can react to real placement
# pressure. The platform metrics autoscale ships with (Percentage CPU,
# Available Memory Bytes) cannot see either of the limits that actually bind:
# the per-node sandbox count cap, and the preallocated hugepage pool that
# sandbox memory is carved out of (allocating from it never moves
# MemAvailable).
#
# Publishing custom metrics requires Microsoft.Insights/Metrics/write, which
# neither Owner nor Contributor grants — only Monitoring Metrics Publisher
# does. Scoped to the resource group, which is dedicated to this e2b stack.
resource "azurerm_role_assignment" "instances_metrics_publisher" {
  scope                = data.azurerm_resource_group.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.infra_instances.principal_id
}

# Scale-in has to be told which nodes it may take. slots-metrics-publisher keeps
# every client instance flagged protectFromScaleIn and clears the flag only on a
# node it has already drained, so autoscale can never remove one that is still
# running sandboxes. Verified on dev: with instance 2 protected, autoscale took
# 1 and then 0 instead, even though its default policy removes the highest
# instance ID first.
#
# Setting that flag is a write against the scale set's VM instances. The
# built-in role carrying it is Virtual Machine Contributor, which also grants
# delete — far more than a metrics publisher should hold. This custom role is
# the two actions and nothing else.
resource "azurerm_role_definition" "vmss_instance_protection" {
  name        = "${var.prefix}vmss-instance-protection"
  scope       = data.azurerm_resource_group.this.id
  description = "Read scale set instances and set their scale-in protection flag. No create, no delete."

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/read",
      "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/write",
    ]
    not_actions = []
  }

  assignable_scopes = [data.azurerm_resource_group.this.id]
}

resource "azurerm_role_assignment" "instances_vmss_protection" {
  scope              = data.azurerm_resource_group.this.id
  role_definition_id = azurerm_role_definition.vmss_instance_protection.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.infra_instances.principal_id
}

