variable "prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

# User-assigned Managed Identity attached to every VM in the pool. Grants the
# node data-plane access to Blob storage, AcrPull, and Key Vault secrets. Mirrors
# the AWS instance IAM role.
variable "identity_id" {
  type = string
}

variable "identity_client_id" {
  type        = string
  description = "clientId of the user-assigned identity; used for `az login --identity` and MSI auth inside the VM."
}

variable "subnet_id" {
  type = string
}

variable "lb_backend_pool_ids" {
  type        = list(string)
  description = "L4 LB backend address pools the primary ipconfiguration joins. Empty for the control-server pool (Nomad UI is reached in-cluster)."
  default     = []
}

variable "cluster_tag_name" {
  type = string
}

variable "cluster_tag_value" {
  type = string
}

# ---
# Setup script delivery (Blob). run-consul/run-nomad are uploaded to the setup
# container by the parent nomad-cluster module and downloaded at boot via the
# Managed Identity.
# ---
variable "storage_account_name" {
  type = string
}

variable "setup_container_name" {
  type = string
}

variable "setup_files_hash" {
  type = map(string)
}

# ---
# Machine / image
# ---
variable "image_id" {
  type        = string
  description = "Resource id of the Packer-built Gen2 image (Shared Image Gallery version or managed image). Empty falls back to an Ubuntu Gen2 marketplace image so the module validates before the Packer chunk lands."
  default     = ""
}

variable "cluster_size" {
  type    = number
  default = 3
}

variable "machine_type" {
  type    = string
  default = "Standard_D2as_v5"
}

variable "os_disk_size_gb" {
  type    = number
  default = 40
}

# ---
# Admin auth. SSH is denied from the internet by the cluster NSG; nodes sit on a
# private subnet with NAT egress. TODO(azure-hardening): switch to admin_ssh_key.
# ---
variable "admin_username" {
  type    = string
  default = "e2b"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

# ---
# Consul / Nomad
# ---
variable "nomad_acl_token" {
  type = string
}

variable "consul_acl_token" {
  type = string
}

variable "consul_gossip_encryption_key" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "scripts_path" {
  type        = string
  description = "Path to the directory containing startup scripts. Defaults to in-module scripts."
  default     = ""
}
