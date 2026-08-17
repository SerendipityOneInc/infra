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

variable "acmebot_mail_address" {
  type        = string
  description = "ACME (Let's Encrypt) account email for keyvault-acmebot expiry notices"
  default     = "allenz@srp.one"
}

variable "acmebot_app_base_name" {
  type        = string
  description = <<-EOT
    Base name for the keyvault-acmebot resources. The module derives globally
    unique names from it (storage account st<name>, function app func-<name>),
    so every environment needs its own value. Empty falls back to
    "<prefix>-acmebot", which dev already owns — set it explicitly for any
    other environment.
  EOT
  default     = ""
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

variable "commit_sha" {
  type        = string
  description = <<-EOT
    Short git commit SHA identifying the raw Go binaries (orchestrator,
    template-manager, nomad-nodepool-apm) to pull from the fc-env-pipeline Blob
    container. e2b uploads a per-SHA copy of each binary; the Nomad artifact
    source references the "<name>.<commit_sha>" blob so a redeploy re-pulls only
    when the SHA changes (mirrors AWS etag / GCP generation).
  EOT
}

variable "image_tag" {
  type        = string
  description = "ACR image tag deployed for the api/db-migrator/client-proxy containers. Defaults to :latest; override to pin a commit SHA."
  default     = "latest"
}

variable "redis_managed" {
  type        = bool
  description = "When true, point every service at redis_external_url and do not schedule the in-cluster redis Nomad job."
  default     = true
}

variable "redis_external_url" {
  type        = string
  description = <<-EOT
    host:port of an external Redis, used when redis_managed = true.

    A bare address, no scheme and no credentials: the e2b Redis client builds
    redis.Options{Addr: ...} and never sets Username/Password/TLSConfig, so a
    Redis that demands AUTH or TLS cannot be reached without a code change.
    That rules out Azure Managed Redis as-is (it forces both) and is why the
    self-hosted deployment runs with auth disabled inside the VNet — the same
    posture as the in-cluster Nomad job it replaces.
  EOT
  default     = ""
}

variable "traefik_config_files" {
  type        = map(string)
  description = "Map of filename => content for additional Traefik dynamic configuration files rendered into the ingress job."
  default     = {}
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

variable "client_max_sandboxes_per_node" {
  type        = number
  description = <<-EOT
    Sandboxes a single client node accepts before it refuses placement. Must
    track the orchestrator's max-sandboxes-per-node feature flag (default 200):
    it is the denominator of the count half of the published slot-utilisation
    metric, so a mismatch silently mis-scales the pool.
  EOT
  default     = 200
}

variable "build_max_instances" {
  type        = number
  description = "Autoscale ceiling for the build pool. null keeps it fixed at build_cluster_size."
  default     = null
}

variable "template_manager_memory_max_mb" {
  type        = number
  description = <<-EOT
    Nomad memory_max for the template-manager task, in MiB. -1 (the default)
    lets it oversubscribe without bound: a burst of concurrent builds then
    exhausts the build node and Firecracker restores fail with "mmap memfd:
    cannot allocate memory". Set it below node memory so Nomad kills the task
    instead of the node running out. Pair it with the team tier's
    concurrent_template_builds, which is what actually caps the burst.
  EOT
  default     = -1
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


# --- Network reuse (Phase C: co-locate on the shared zooclaw-dev-vnet) --------
variable "existing_vnet_name" {
  type        = string
  description = "Existing VNet to add e2b subnets to (reach private-endpoint PG + JuiceFS). Empty = dedicated VNet."
  default     = ""
}

variable "existing_vnet_resource_group" {
  type        = string
  description = "Resource group of existing_vnet_name."
  default     = ""
}

variable "cluster_subnet_cidr" {
  type        = string
  description = "CIDR for the e2b cluster subnet."
  default     = "10.0.0.0/20"
}

variable "services_subnet_cidr" {
  type        = string
  description = "CIDR for the e2b auxiliary services subnet."
  default     = "10.0.16.0/20"
}

variable "appgw_subnet_cidr" {
  type        = string
  description = <<-EOT
    CIDR for the dedicated Application Gateway v2 subnet (the gateway requires a
    subnet of its own). When co-locating on an existing VNet this must fall
    inside that VNet's address space, so every such environment overrides it.
    The default is the free /24 in the dev VNet.
  EOT
  default     = "10.180.160.0/24"
}

# --- Reuse the base-infra Postgres Flexible Server (create the e2b DB on it) ---
variable "existing_pg_server_name" {
  type        = string
  description = "Existing Postgres Flexible Server (from azure-foundation) to create the e2b database on. Empty = don't manage a database."
  default     = ""
}

variable "existing_pg_resource_group" {
  type        = string
  description = "Resource group of existing_pg_server_name."
  default     = ""
}

variable "e2b_database_name" {
  type        = string
  description = "Name of the database e2b creates on the existing Postgres server."
  default     = "e2b"
}

variable "juicefs_volumes" {
  type = list(object({
    console_url   = string
    token_secret  = string
    volume        = string
    mount_path    = string
    subdir        = string
    cache_group   = string
    mount_options = string
  }))
  description = "JuiceFS EE volumes auto-mounted on client/build nodes at boot. token_secret is a Key Vault secret name (read via node MI); object access keyless via MI. mount_path must equal local.juicefs_mount_path so the orchestrator's PERSISTENT_VOLUME_MOUNTS lines up."
  default     = []
}

variable "client_scale_out_memory_free_bytes" {
  type        = number
  default     = null
  description = "orch-client autoscale: scale out when avg available memory < bytes."
}

variable "client_scale_in_memory_free_bytes" {
  type        = number
  default     = null
  description = "orch-client autoscale: extra scale-in condition, avg available memory > bytes."
}

variable "client_scale_out_slots_used_percentage" {
  type        = number
  default     = null
  description = <<-EOT
    orch-client autoscale: scale out when average sandbox slot utilisation
    exceeds this percentage. Utilisation is max(sandboxes/cap, allocated
    memory/hugepage capacity), published by slots-metrics-publisher — the CPU
    and available-memory rules cannot see either limit. Keep it well under 100:
    a scale-out takes minutes, a sandbox create takes ~1s.
  EOT
}

variable "client_scale_in_cpu_threshold" {
  type        = number
  default     = 25
  description = <<-EOT
    orch-client autoscale: the Decrease rule's CPU threshold. This rule does not
    decide anything on its own — it only makes Azure willing to remove an
    instance. Which instance, and whether removing one is safe at all, is
    decided by slots-metrics-publisher through scale-in protection. Set to null
    to disable removal entirely.
  EOT
}

variable "client_reclaim_enabled" {
  type        = bool
  default     = false
  description = <<-EOT
    Allow the pool to shrink. The publisher drains the emptiest node, waits for
    it to empty, then clears its scale-in protection so autoscale removes that
    node and no other. Off by default: with it off every instance stays
    protected and the pool only grows, matching upstream GCP's ONLY_SCALE_OUT.
  EOT
}

variable "client_reclaim_below_pct" {
  type        = number
  default     = 30
  description = "Only shed a node while average pool utilisation is under this. Shedding also requires the post-removal projection to stay under the scale-out threshold, so the pool cannot shed itself into an immediate scale-out."
}

variable "client_reclaim_min_nodes" {
  type        = number
  default     = null
  description = "Floor on client nodes when reclaiming. null uses client_cluster_size."
}

variable "dashboard_api_count" {
  type    = number
  default = 1
}

variable "billing_gateway_count" {
  type        = number
  default     = 1
  description = "Number of sandbox billing read gateway instances. Use 1 in staging and 2 in production."

  validation {
    condition     = var.billing_gateway_count >= 0 && var.billing_gateway_count <= 2
    error_message = "billing_gateway_count must be between 0 and 2."
  }
}

variable "billing_gateway_previous_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Previous gateway bearer token accepted temporarily during rotation."

  validation {
    condition     = var.billing_gateway_previous_token == "" || length(var.billing_gateway_previous_token) >= 32
    error_message = "billing_gateway_previous_token must be empty or at least 32 characters."
  }
}

variable "billing_max_query_range_days" {
  type        = number
  description = <<-EOT
    Widest time window the sandbox billing read gateway will accept, in days.

    Keep it at or below the event retention actually in force. Retention is
    per-team (tiers.events_ttl_days in Postgres, applied as a per-row TTL on
    sandbox_events), so raising a team's retention without raising this leaves
    data the consumer cannot reach, and raising this above the retention makes
    wide queries return a silently short answer instead of an error.
  EOT
  default     = 7
}
