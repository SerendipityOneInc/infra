variable "domain_name" {
  type        = string
  description = "The domain (or subdomain) where e2b runs, e.g. e2b.example.com or example.dev. The Cloudflare zone (root domain) is derived from this."
}

variable "lb_frontend_ip" {
  type        = string
  description = "Public frontend IP of the Azure L4 load balancer. All records point here."
}

variable "proxied_subdomains" {
  type        = list(string)
  description = "Control-plane subdomains that are proxied through Cloudflare (edge WAF/DDoS/TLS). Each becomes '<sub>.<domain_name>'."
  default     = ["api", "grpc-api", "nomad", "docker"]
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
