job "ingress" {
  node_pool = "${node_pool}"
  priority  = 90

  group "ingress" {
    count = ${count}

    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    network {
      port "control" {
        static = "${control_port}"
      }

      port "ingress" {
        static = "${ingress_port}"
      }

      port "ingress-internal" {
        static = "${ingress_internal_port}"
      }
%{ if tls_enabled }
      port "ingress-secure" {
        static = "${ingress_secure_port}"
      }
%{ endif }
    }
%{ if tls_enabled }
    # Persist the ACME account key + issued certs across restarts so Traefik
    # does not re-request from Let's Encrypt on every reschedule.
    volume "acme" {
      type   = "host"
      source = "${acme_volume_name}"
    }
%{ endif }

# https://developer.hashicorp.com/nomad/docs/job-specification/update
%{ if update_stanza }
    update {
      # The number of instances that can be updated at the same time
      max_parallel     = 1
      # Number of extra instances that can be spawn before killing the old one
      canary           = 1
      # Time to wait for the canary to be healthy
      min_healthy_time = "10s"
      # Time to wait for the canary to be healthy, if not it will be marked as failed
      healthy_deadline = "30s"
      # Whether to promote the canary if the rest of the group is not healthy
      auto_promote     = true
      # Deadline for the update to be completed
      progress_deadline = "24h"
    }
%{ endif }

    service {
      port = "ingress"
      name = "ingress"
      task = "ingress"

      check {
        type     = "http"
        name     = "health"
        path     = "/ping"
        interval = "3s"
        timeout  = "3s"
        port     = "${ingress_port}"
      }
    }

    # Expose Nomad dashboard and API via Traefik ingress
    service {
      name = "ingress-dashboard"
      port = "control"
      task = "ingress"

      tags = [
        "traefik.enable=true",

        "traefik.http.routers.traefik.rule=PathPrefix(`/dashboard`) || PathPrefix(`/api`)",
        "traefik.http.routers.traefik.entrypoints=traefik",
        "traefik.http.routers.traefik.service=api@internal",
      ]
    }

    task "ingress" {
      driver = "docker"

      %{ if update_stanza }
        kill_timeout = "24h"
      %{ endif }
      kill_signal  = "SIGTERM"

      config {
        network_mode = "host"
        image        = "traefik:v3.5"
        ports        = ["control", "ingress", "ingress-internal"%{ if tls_enabled }, "ingress-secure"%{ endif }]
        args = [
          "--configFile=/local/traefik.toml",
        ]
      }
%{ if tls_enabled }
      # Cloudflare token for the ACME DNS-01 challenge (read by Traefik's
      # cloudflare provider). Sandbox data plane only; empty on non-TLS providers.
      env {
        CF_DNS_API_TOKEN = "${cf_dns_api_token}"
      }

      volume_mount {
        volume      = "acme"
        destination = "/acme"
      }
%{ endif }

      template {
        data        = <<EOF
${traefik_config}
EOF
        destination = "local/traefik.toml"
      }

      template {
        data = "# content ignored, ensures the directory exists"
        destination = "local/config/.keep"
      }

%{ for filename, content in config_files }
      template {
        data        = <<EOF
${content}
EOF
        destination = "local/config/${filename}"
      }
%{ endfor }

      resources {
        memory_max = ${memory_mb * 1.5}
        memory     = ${memory_mb}
        cpu        = ${cpu_count * 1000}
      }
    }
  }
}
