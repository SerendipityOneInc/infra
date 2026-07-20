# ---
# Azure account / auth
# ---
variable "subscription_id" {
  type        = string
  description = "Azure subscription id that holds the Compute Gallery (Shared Image Gallery) the built image version is published to."
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant id. Only needed for service-principal auth; ignored when using Azure CLI auth."
  default     = ""
}

variable "client_id" {
  type        = string
  description = "Service-principal client id. Leave empty to authenticate via the Azure CLI (use_azure_cli_auth)."
  default     = ""
}

variable "client_secret" {
  type        = string
  description = "Service-principal client secret. Leave empty when using Azure CLI auth."
  default     = ""
  sensitive   = true
}

variable "location" {
  type        = string
  description = "Azure region to build in and to replicate the gallery image version to (e.g. centralus)."
}

# ---
# Base image / build VM
# ---
# Ubuntu 22.04 Jammy Gen2, matching the nodepool marketplace fallback
# (publisher=Canonical, offer=0001-com-ubuntu-server-jammy, sku=22_04-lts-gen2).
variable "image_publisher" {
  type    = string
  default = "Canonical"
}

variable "image_offer" {
  type    = string
  default = "0001-com-ubuntu-server-jammy"
}

variable "image_sku" {
  type    = string
  default = "22_04-lts-gen2"
}

# The build VM does NOT need nested virtualization (Firecracker/kernel/envd are
# fetched at runtime, not baked). A general-purpose SKU keeps the build cheap.
variable "base_vm_size" {
  type    = string
  default = "Standard_D4as_v5"
}

# ---
# Shared Image Gallery (Azure Compute Gallery) destination
# ---
variable "gallery_resource_group" {
  type        = string
  description = "Resource group that holds the Azure Compute Gallery and the image definition."
}

variable "gallery_name" {
  type        = string
  description = "Name of the Azure Compute Gallery (Shared Image Gallery) to publish into."
}

variable "image_name" {
  type        = string
  description = "Name of the gallery image definition (must already exist in the gallery; Gen2 / hyperVGeneration V2, Linux)."
}

variable "image_version" {
  type        = string
  description = "Semantic gallery image version to publish, e.g. 1.0.0 or a date-derived version."
  default     = "1.0.0"
}

# ---
# Naming
# ---
variable "prefix" {
  type    = string
  default = "e2b-"
}

# ---
# Provisioner tool versions (kept in sync with provider-aws / provider-gcp)
# ---
variable "consul_version" {
  type    = string
  default = "1.17.3"
}

variable "nomad_version" {
  type    = string
  default = "1.8.4"
}

# Keep in sync with `clickhouse_version` in iac/modules/job-clickhouse/variables.tf
variable "clickhouse_client_version" {
  type    = string
  default = "25.4.5.24"
}

variable "cni_plugin_version" {
  type    = string
  default = "v1.6.2"
}

# docker-credential-acr-env (Azure ACR docker credential helper) release version.
# https://github.com/chrismellard/docker-credential-acr-env/releases
variable "acr_cred_helper_version" {
  type    = string
  default = "0.7.0"
}
