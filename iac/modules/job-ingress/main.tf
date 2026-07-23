locals {
  # TLS needs the resolver token; treat an empty token as "off" regardless of
  # the flag so a half-configured provider never renders a broken resolver.
  tls_enabled = var.tls_enabled && var.cf_dns_api_token != ""

  traefik_config = templatefile("${path.module}/jobs/traefik.toml", {
    control_port          = var.control_port
    ingress_port          = var.ingress_port
    ingress_internal_port = var.ingress_internal_port

    nomad_endpoint = var.nomad_endpoint
    nomad_token    = var.nomad_token

    consul_endpoint = var.consul_endpoint
    consul_token    = var.consul_token

    otel_collector_grpc_endpoint = var.otel_collector_grpc_endpoint

    tls_enabled         = local.tls_enabled
    ingress_secure_port = var.ingress_secure_port
    acme_email          = var.acme_email
    acme_domains        = var.acme_domains
  })
}

resource "nomad_job" "ingress" {
  jobspec = templatefile("${path.module}/jobs/ingress.hcl", {
    count         = var.ingress_count
    node_pool     = var.node_pool
    update_stanza = var.update_stanza
    cpu_count     = var.ingress_cpu_count
    memory_mb     = var.ingress_memory_mb

    control_port          = var.control_port
    ingress_port          = var.ingress_port
    ingress_internal_port = var.ingress_internal_port

    traefik_config = local.traefik_config
    config_files   = var.traefik_config_files

    tls_enabled         = local.tls_enabled
    ingress_secure_port = var.ingress_secure_port
    cf_dns_api_token    = var.cf_dns_api_token
    acme_volume_name    = var.acme_volume_name
  })
}
