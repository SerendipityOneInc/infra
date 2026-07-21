variable "prefix" {
  type = string
}

variable "name" {
  type        = string
  description = "Short pool name suffix (e.g. orch-client, orch-build). Disambiguates the two VMSS built from this module."
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "identity_id" {
  type = string
}

variable "identity_client_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "appgw_backend_pool_ids" {
  type        = list(string)
  description = "Application Gateway backend pools joined by the primary ipconfiguration. The client pool joins the ingress pool (client-proxy serves ingress); the build pool passes []."
  default     = []
}

variable "cluster_tag_name" {
  type = string
}

variable "cluster_tag_value" {
  type = string
}

variable "storage_account_name" {
  type = string
}

variable "setup_container_name" {
  type = string
}

variable "setup_files_hash" {
  type = map(string)
}

variable "image_id" {
  type    = string
  default = ""
}

variable "cluster_size" {
  type    = number
  default = 1
}

variable "machine_type" {
  type        = string
  default     = "Standard_E32ads_v5"
  description = "Nested-virtualization-capable AMD SKU with a local temp/NVMe disk (Firecracker host)."
}

variable "os_disk_size_gb" {
  type    = number
  default = 500
}

variable "admin_username" {
  type    = string
  default = "e2b"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "node_pool_name" {
  type = string
}

variable "node_labels" {
  type        = list(string)
  description = "Scheduling labels for Nomad."
  default     = []
}

variable "base_hugepages_percentage" {
  type    = number
  default = 60
}

variable "nested_virtualization" {
  type        = bool
  default     = true
  description = "Informational on Azure: nested virt is a property of the SKU (E-ads/D-ads v5 support it), not a settable knob like the AWS cpu_options. Kept for parity."
}

variable "set_orchestrator_version_metadata" {
  type        = bool
  description = "When true, the node fetches the pinned orchestrator job version from Nomad before starting its client (SRP orchestrator-version handshake)."
  default     = true
}

variable "nomad_acl_token" {
  type        = string
  description = "Nomad ACL token used by the orchestrator-version handshake to read the pinned job version."
  default     = ""
}

variable "consul_acl_token" {
  type = string
}

variable "consul_gossip_encryption_key" {
  type = string
}

variable "consul_dns_request_token" {
  type = string
}

variable "acr_login_server" {
  type = string
}

# ---
# Blob containers mounted read-only via blobfuse2 (replaces gcsfuse / s3fs).
# ---
variable "fc_env_pipeline_container_name" {
  type = string
}

variable "fc_kernels_container_name" {
  type = string
}

variable "fc_versions_container_name" {
  type = string
}

variable "fc_busybox_container_name" {
  type = string
}

# ---
# Autoscale (azurerm_monitor_autoscale_setting). Mirrors the AWS ASG CPU-based
# scaling. min defaults to cluster_size; raise max_instances to enable real
# scale-out.
# ---
variable "min_instances" {
  type    = number
  default = null
}

variable "max_instances" {
  type    = number
  default = null
}

variable "scale_out_cpu_threshold" {
  type    = number
  default = 75
}

variable "scale_in_cpu_threshold" {
  type    = number
  default = 25
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "scripts_path" {
  type    = string
  default = ""
}
