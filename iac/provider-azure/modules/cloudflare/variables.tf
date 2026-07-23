variable "domain_name" {
  type        = string
  description = "The domain (or subdomain) where e2b runs, e.g. e2b.example.com or example.dev. The Cloudflare zone (root domain) is derived from this."
}

variable "lb_frontend_ip" {
  type        = string
  description = "Public frontend IP of the Azure Application Gateway. All records point here."
}

variable "proxied_subdomains" {
  type        = list(string)
  description = "Control-plane subdomains that are proxied through Cloudflare (edge WAF/DDoS/TLS). Each becomes '<sub>.<domain_name>'. nomad. is now proxied HTTPS through the App Gateway (Full SSL mode)."
  default     = ["api", "grpc-api", "nomad", "docker"]
}

variable "direct_subdomains" {
  type        = list(string)
  description = "Subdomains created DNS-only (grey cloud), pointing straight at the App Gateway frontend IP. Empty now that nomad. is proxied HTTPS through the gateway."
  default     = []
}

variable "wildcard_ttl" {
  type        = number
  description = "TTL for the DNS-only per-sandbox wildcard record"
  default     = 3600
}

variable "comment" {
  type        = string
  description = "Comment attached to each Cloudflare record (e.g. environment or subscription id)"
  default     = "managed by terraform (provider-azure)"
}

variable "wildcard_ip" {
  type        = string
  description = "IP the per-sandbox wildcard (*.<domain>) points at — the sandbox data-plane L4 LB. Empty falls back to lb_frontend_ip (App Gateway)."
  default     = ""
}
