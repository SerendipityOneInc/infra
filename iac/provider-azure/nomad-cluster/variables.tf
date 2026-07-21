variable "prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

# ---
# Identity / network (from module.init and module.network)
# ---
variable "identity_id" {
  type        = string
  description = "Resource id of the user-assigned Managed Identity attached to every VMSS."
}

variable "identity_client_id" {
  type        = string
  description = "clientId of the user-assigned Managed Identity (MSI auth inside the VM)."
}

variable "cluster_subnet_id" {
  type = string
}

variable "client_appgw_backend_pool_ids" {
  type        = list(string)
  description = "App Gateway backend pools the client pool joins (client-proxy serves ingress). Server/api/clickhouse pools join their own pools or none."
  default     = []
}

# ---
# Cluster secrets (from module.init.cluster)
# ---
variable "nomad_acl_token_secret" {
  type = string
}

variable "consul_acl_token_secret" {
  type = string
}

variable "consul_dns_request_token_secret" {
  type = string
}

variable "consul_gossip_encryption_key" {
  type = string
}

# ---
# Object storage (single account, per-role containers) + ACR
# ---
variable "storage_account_name" {
  type = string
}

variable "setup_container_name" {
  type = string
}

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

variable "acr_login_server" {
  type = string
}

# ---
# Admin auth (SSH denied from internet by NSG; nodes on a private subnet).
# ---
variable "admin_username" {
  type    = string
  default = "e2b"
}

# ---
# Control server
# ---
variable "control_server_cluster_size" {
  type = number
}

variable "control_server_machine_type" {
  type = string
}

variable "control_server_image_id" {
  type    = string
  default = ""
}

# ---
# API
# ---
variable "api_node_pool_name" {
  type = string
}

variable "api_cluster_size" {
  type = number
}

variable "api_machine_type" {
  type = string
}

variable "api_image_id" {
  type    = string
  default = ""
}

variable "api_appgw_backend_pool_ids" {
  type    = list(string)
  default = []
}

# ---
# Client (Firecracker hosts)
# ---
variable "client_node_pool_name" {
  type = string
}

variable "client_cluster_size" {
  type = number
}

variable "client_machine_type" {
  type = string
}

variable "client_image_id" {
  type    = string
  default = ""
}

variable "client_node_labels" {
  type    = list(string)
  default = []
}

variable "client_server_nested_virtualization" {
  type    = bool
  default = true
}

variable "client_base_hugepages_percentage" {
  type    = number
  default = 60
}

variable "client_max_instances" {
  type    = number
  default = null
}

# ---
# Build (Template Manager)
# ---
variable "build_node_pool_name" {
  type = string
}

variable "build_cluster_size" {
  type = number
}

variable "build_machine_type" {
  type = string
}

variable "build_image_id" {
  type    = string
  default = ""
}

variable "build_node_labels" {
  type    = list(string)
  default = []
}

variable "build_server_nested_virtualization" {
  type    = bool
  default = true
}

variable "build_max_instances" {
  type    = number
  default = null
}

# ---
# ClickHouse
# ---
variable "clickhouse_node_pool_name" {
  type = string
}

variable "clickhouse_cluster_size" {
  type = number
}

variable "clickhouse_machine_type" {
  type = string
}

variable "clickhouse_image_id" {
  type    = string
  default = ""
}

variable "clickhouse_job_constraint_prefix" {
  type = string
}

variable "server_appgw_backend_pool_ids" {
  type        = list(string)
  description = "App Gateway backend address pool ids the control-server (Nomad/Consul server) VMSS joins, so the gateway's nomad.<domain> listener routes straight to the servers on 4646."
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
