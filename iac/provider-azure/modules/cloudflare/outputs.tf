output "zone_id" {
  value = data.cloudflare_zone.domain.zone_id
}

output "root_domain" {
  value = local.root_domain
}

output "proxied_record_hostnames" {
  description = "FQDNs of the proxied (orange-cloud) control-plane records"
  value       = [for r in cloudflare_record.control_plane : r.hostname]
}

output "wildcard_record_hostname" {
  description = "FQDN of the DNS-only per-sandbox wildcard record"
  value       = cloudflare_record.wildcard.hostname
}
