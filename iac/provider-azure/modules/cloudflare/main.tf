terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.52.5"
    }
  }
}

# ============================================================================
# Cloudflare DNS for the Azure deployment.
#
# Mirrors provider-aws/domain.tf (the wildcard routing record) and the GCP
# nomad-cluster/network cloudflare records, but adapted to the L4 design:
#
#   * Control-plane hostnames (api., grpc-api., nomad., docker.) are PROXIED
#     (orange cloud) so Cloudflare provides edge WAF/DDoS and terminates TLS
#     at the edge in front of the L4 LB.
#   * The per-sandbox wildcard *.<domain> is DNS-only (grey cloud): sandbox
#     traffic goes straight to the LB frontend IP, where the in-cluster ingress
#     terminates TLS and routes per host/path. Proxying the wildcard would break
#     arbitrary sandbox ports/subdomains, so it stays direct.
#
# All records are simple A records to the single LB frontend IP.
# ============================================================================

locals {
  domain_parts        = split(".", var.domain_name)
  domain_is_subdomain = length(local.domain_parts) > 2

  # Cloudflare zone = the registrable root domain (last two labels).
  root_domain = local.domain_is_subdomain ? join(".", slice(local.domain_parts, length(local.domain_parts) - 2, length(local.domain_parts))) : var.domain_name
}

data "cloudflare_zone" "domain" {
  name = local.root_domain
}

# Control-plane records: proxied (orange cloud). Cloudflare requires ttl = 1
# ("automatic") for proxied records.
resource "cloudflare_record" "control_plane" {
  for_each = toset(var.proxied_subdomains)

  zone_id = data.cloudflare_zone.domain.zone_id
  name    = "${each.value}.${var.domain_name}"
  type    = "A"
  value   = var.lb_frontend_ip
  proxied = true
  ttl     = 1
  comment = var.comment
}

# Per-sandbox wildcard: DNS-only (grey cloud), pointing straight at the LB.
resource "cloudflare_record" "wildcard" {
  zone_id = data.cloudflare_zone.domain.zone_id
  name    = "*.${var.domain_name}"
  type    = "A"
  value   = var.lb_frontend_ip
  proxied = false
  ttl     = var.wildcard_ttl
  comment = var.comment
}
