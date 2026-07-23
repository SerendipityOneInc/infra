# Core
variable "domain_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "resource_group_name" {
  type        = string
  description = "Deployment resource group; used to look up the storage account for SAS generation."
}

# Auth
variable "nomad_acl_token" {
  type      = string
  sensitive = true
}

variable "consul_acl_token" {
  type      = string
  sensitive = true
}

# Node pools
variable "api_node_pool" {
  type = string
}

variable "orchestrator_node_pool" {
  type = string
}

variable "build_node_pool" {
  type = string
}

# Cluster sizes
variable "api_cluster_size" {
  type = number
}

variable "build_cluster_size" {
  type    = number
  default = 1
}

# ---
# Object storage (artifact delivery). go-getter has no native azblob getter, so
# the raw Go binaries are pulled over plain HTTPS from the fc-env-pipeline Blob
# container using a read-only container SAS for auth. The storage account is
# re-read here (by name + resource group) so we can mint the SAS without adding a
# key output to module.init.
# ---
variable "storage_account_name" {
  type        = string
  description = "Storage account backing object storage (from module.init.storage_account_name)."
}

variable "fc_env_pipeline_container_name" {
  type        = string
  description = "Blob container holding the raw Go binaries (from module.init.fc_env_pipeline_container_name)."
}

variable "commit_sha" {
  type        = string
  description = <<-EOT
    Short git commit SHA identifying the binaries to pull. e2b uploads a per-SHA
    copy of each binary (e.g. template-manager.<sha>) alongside the mutable name.
    Used both as the versioned blob name and as the artifact cache-buster: the
    artifact_source string only changes when this changes, so a redeploy re-pulls
    only on a new SHA (mirrors AWS etag / GCP generation).
  EOT
}

variable "sas_start" {
  type        = string
  description = <<-EOT
    Fixed ISO-8601 start time for the read-only container SAS. Intentionally
    static (not timestamp()) so the SAS signature is deterministic across applies
    and the artifact_source only changes when commit_sha changes.
  EOT
  default     = "2024-01-01T00:00:00Z"
}

variable "sas_expiry" {
  type        = string
  description = "Fixed ISO-8601 expiry for the read-only container SAS. Static for the same deterministic-source reason as sas_start."
  default     = "2035-01-01T00:00:00Z"
}

# ---
# Container registry (ACR) image refs. ACR repository names already include the
# "<prefix>core/<component>" path; the full ref is
# "<acr_login_server>/<repository_name>:<image_tag>".
# ---
variable "acr_login_server" {
  type = string
}

variable "image_tag" {
  type        = string
  description = "ACR image tag to deploy. Images are pushed as :latest and :<commit_sha>; override to pin a SHA."
  default     = "latest"
}

variable "api_repository_name" {
  type = string
}

variable "db_migrator_repository_name" {
  type = string
}

variable "client_proxy_repository_name" {
  type = string
}

# Ingress
variable "ingress_port" {
  type        = number
  description = "External traffic port number"
}

variable "ingress_internal_port" {
  type        = number
  description = "Internal traffic port number"
}

variable "ingress_count" {
  type = number
}

variable "traefik_config_files" {
  type    = map(string)
  default = {}
}

# API
variable "api_port" {
  type    = number
  default = 80
}

variable "api_internal_grpc_port" {
  type    = number
  default = 5009
}

variable "api_memory_mb" {
  type    = number
  default = 512
}

variable "api_cpu_count" {
  type    = number
  default = 1
}

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

# Client proxy
variable "client_proxy_count" {
  type    = number
  default = 1
}

variable "client_proxy_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

# Orchestrator
variable "orchestrator_port" {
  type    = number
  default = 5008
}

variable "orchestrator_proxy_port" {
  type    = number
  default = 5007
}

variable "orchestrator_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

# Template manager
variable "template_manager_port" {
  type    = number
  default = 5008
}

variable "template_manager_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

# Redis
variable "redis_managed" {
  type    = bool
  default = true
}

variable "redis_port" {
  type    = number
  default = 6379
}

# Telemetry
variable "otel_collector_grpc_port" {
  type    = number
  default = 4317
}

variable "dataplane_tls_enabled" {
  type        = bool
  description = "Enable Traefik's TLS websecure entrypoint + h2c client-proxy backend for the L4 data-plane path."
  default     = false
}

variable "internal_domain_name" {
  type        = string
  description = "Internal-only domain (in-VNet) whose wildcard cert Traefik also requests."
  default     = ""
}

variable "acme_email" {
  type    = string
  default = ""
}

variable "cf_dns_api_token" {
  type      = string
  default   = ""
  sensitive = true
}
