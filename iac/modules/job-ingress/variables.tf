variable "nomad_token" {
  type      = string
  sensitive = true
}

variable "nomad_endpoint" {
  type    = string
  default = "http://localhost:4646"
}

variable "consul_token" {
  type      = string
  sensitive = true
}

variable "consul_endpoint" {
  type    = string
  default = "http://localhost:8500"
}

variable "control_port" {
  type    = number
  default = 8900
}

variable "ingress_port" {
  type = number
}

variable "ingress_internal_port" {
  type = number
}

variable "node_pool" {
  type = string
}

variable "update_stanza" {
  type = bool
}

variable "ingress_count" {
  type = number
}

variable "ingress_cpu_count" {
  type    = number
  default = 1
}

variable "ingress_memory_mb" {
  type    = number
  default = 512
}

variable "otel_collector_grpc_endpoint" {
  type        = string
  description = "OpenTelemetry collector gRPC endpoint (e.g., localhost:4317)"
}

variable "traefik_config_files" {
  type        = map(string)
  description = "Map of filename => content for additional Traefik dynamic configuration files"
}

# ---------------------------------------------------------------------------
# Optional TLS-terminating entrypoint for the sandbox data plane.
#
# On Azure, sandbox traffic bypasses the App Gateway (which can only speak
# HTTP/1.1 to backends and therefore breaks bidirectional gRPC/connect streams
# like PTY) and reaches Traefik directly through an L4 (TCP-passthrough) load
# balancer. Traefik then terminates TLS here (advertising h2 via ALPN) and
# talks h2c to client-proxy, preserving HTTP/2 end to end.
#
# Default off, so providers that terminate TLS at their cloud LB (GCP HTTPS LB
# H2C backend, AWS ALB) are entirely unaffected.
# ---------------------------------------------------------------------------
variable "tls_enabled" {
  type        = bool
  description = "Enable a TLS-terminating websecure entrypoint with an ACME (Let's Encrypt) resolver. Requires acme_email, acme_domains and cf_dns_api_token."
  default     = false
}

variable "ingress_secure_port" {
  type    = number
  default = 443
}

variable "acme_email" {
  type    = string
  default = ""
}

variable "acme_domains" {
  type = list(object({
    main = string
    sans = list(string)
  }))
  description = "Certificate domains for the ACME resolver (e.g. {main=sandbox2.yesy.dev, sans=[*.sandbox2.yesy.dev]}). Declared so Traefik requests one wildcard cert per domain instead of one per sandbox SNI."
  default     = []
}

variable "cf_dns_api_token" {
  type        = string
  description = "Cloudflare API token for the ACME DNS-01 challenge (env CF_DNS_API_TOKEN). Empty disables TLS regardless of tls_enabled."
  default     = ""
  sensitive   = true
}

variable "acme_volume_name" {
  type        = string
  description = "Nomad host_volume name backing persistent ACME storage (acme.json). Declared on the client agents that run ingress."
  default     = "traefik-acme"
}
