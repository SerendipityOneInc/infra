# ---
# Azure account / location
# ---
variable "subscription_id" {
  type        = string
  description = "The Azure subscription id to deploy into"
}

variable "tenant_id" {
  type        = string
  description = "The Azure AD tenant id"
}

variable "location" {
  type        = string
  description = "The Azure region for all resources"
}

variable "resource_group_name" {
  type        = string
  description = "The resource group that holds the deployment"
}

# ---
# Naming
# ---
variable "prefix" {
  type        = string
  description = "Name prefix for all resources"
  default     = "e2b-"
}

variable "domain_name" {
  type        = string
  description = "The domain name where e2b will run"
}

variable "environment" {
  type        = string
  description = "The deployment environment (dev, staging, prod)"
}

# ---
# Object storage / registry / secrets
# ---
variable "storage_account_name" {
  type        = string
  description = "Globally-unique Azure Storage account name backing object storage (3-24 lowercase alphanumeric characters)"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase alphanumeric characters (Azure Storage account naming rules)."
  }
}

variable "acr_name" {
  type        = string
  description = "Globally-unique Azure Container Registry name (5-50 alphanumeric characters)"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "acr_name must be 5-50 alphanumeric characters (Azure Container Registry naming rules)."
  }
}

variable "key_vault_name" {
  type        = string
  description = "Globally-unique Key Vault name (3-24 alphanumeric/hyphen, must start with a letter). Defaults to a name derived from the storage account name when empty."
  default     = ""
}

variable "postgres_connection_string" {
  type        = string
  description = "Postgres DSN (Azure Database for PostgreSQL Flexible Server). Seeded into Key Vault; may be a placeholder and edited out of band."
  default     = " "
  sensitive   = true
}

variable "remote_repository_enabled" {
  type        = bool
  description = "Set to true to create a DockerHub pull-through cache rule on the ACR"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags to attach to resources created by this deployment"
  default = {
    app       = "e2b"
    terraform = "true"
  }
}

# ---
# Job env-var overrides (threaded into the Nomad jobs once module.nomad lands)
# ---
variable "api_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "api_db_migrator_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "client_proxy_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "orchestrator_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "template_manager_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

# ---
# Ports / connections
# ---
variable "orchestrator_port" {
  type    = number
  default = 5008
}

variable "orchestrator_proxy_port" {
  type    = number
  default = 5007
}

variable "api_internal_grpc_port" {
  type    = number
  default = 5009
}

variable "envd_timeout" {
  type    = string
  default = "40s"
}

variable "allow_sandbox_internal_cidrs" {
  type        = string
  description = "Comma-separated CIDRs to allow through the sandbox firewall deny list (e.g. 10.0.0.1/32,10.0.0.2/32)"
  default     = ""
}

variable "db_max_open_connections" {
  type    = number
  default = 40
}

variable "db_min_idle_connections" {
  type    = number
  default = 5
}

variable "auth_db_max_open_connections" {
  type    = number
  default = 20
}

variable "auth_db_min_idle_connections" {
  type    = number
  default = 5
}

# ---
# Machine sizes / cluster sizes. Carried forward now so the Makefile tf_vars line
# up even though the compute plane (nomad-cluster) is a later chunk. Defaults use
# Azure VM SKUs; the client/build SKUs are nested-virtualization-capable.
# ---
# Packer-built Gen2 image (Shared Image Gallery version id or managed image id).
# Common default for every pool; per-pool overrides below take precedence. Empty
# means the nodepool modules fall back to an Ubuntu Gen2 marketplace image so the
# stack validates/bootstraps before the Packer chunk lands.
variable "cluster_image_id" {
  type        = string
  description = "Resource id of the Packer-built Gen2 image used by all node pools unless a per-pool override is set."
  default     = ""
}

variable "control_server_image_id" {
  type    = string
  default = ""
}

variable "api_image_id" {
  type    = string
  default = ""
}

variable "client_image_id" {
  type    = string
  default = ""
}

variable "build_image_id" {
  type    = string
  default = ""
}

variable "clickhouse_image_id" {
  type    = string
  default = ""
}

variable "client_node_labels" {
  type        = list(string)
  description = "Scheduling labels applied to client (Firecracker host) nodes."
  default     = []
}

variable "build_node_labels" {
  type        = list(string)
  description = "Scheduling labels applied to build (template-manager) nodes."
  default     = []
}

variable "client_max_instances" {
  type        = number
  description = "Autoscale ceiling for the client pool. null keeps it fixed at client_cluster_size."
  default     = null
}

variable "build_max_instances" {
  type        = number
  description = "Autoscale ceiling for the build pool. null keeps it fixed at build_cluster_size."
  default     = null
}

variable "control_server_cluster_size" {
  type    = number
  default = 3
}

variable "control_server_machine_type" {
  type        = string
  description = "Azure VM SKU for the control (Nomad/Consul server) nodes"
  default     = "Standard_D2as_v5"
}

variable "api_cluster_size" {
  type    = number
  default = 1
}

variable "api_server_machine_type" {
  type        = string
  description = "Azure VM SKU for the API nodes"
  default     = "Standard_D4as_v5"
}

variable "build_cluster_size" {
  type    = number
  default = 1
}

variable "build_server_machine_type" {
  type        = string
  description = "Azure VM SKU for the build nodes (nested-virtualization capable)"
  default     = "Standard_D8ads_v5"
}

variable "build_server_nested_virtualization" {
  type    = bool
  default = true
}

variable "client_cluster_size" {
  type    = number
  default = 1
}

variable "client_server_machine_type" {
  type        = string
  description = "Azure VM SKU for the client (Firecracker host) nodes (nested-virtualization capable, e.g. Standard_E32ads_v5)"
  default     = "Standard_E32ads_v5"
}

variable "client_server_nested_virtualization" {
  type    = bool
  default = true
}

variable "clickhouse_cluster_size" {
  type    = number
  default = 1
}

variable "clickhouse_server_machine_type" {
  type        = string
  description = "Azure VM SKU for the ClickHouse nodes"
  default     = "Standard_D4as_v5"
}

variable "ingress_count" {
  type    = number
  default = 1
}

variable "client_proxy_count" {
  type    = number
  default = 1
}

