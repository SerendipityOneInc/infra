job "grafana" {
  type      = "service"
  node_pool = "${node_pool}"
  priority  = 60

  group "grafana" {
    restart {
      interval = "5s"
      attempts = 1
      delay    = "5s"
      mode     = "delay"
    }

    # Keep the sqlite state (manually created dashboards, users) across job
    # updates on a best-effort basis. Provisioned datasources are IaC and
    # survive regardless.
    ephemeral_disk {
      size    = 1024
      sticky  = true
      migrate = true
    }

    network {
      # Host networking (like loki) — grafana listens directly on the
      # allocated dynamic port via GF_SERVER_HTTP_PORT.
      port "http" {}
    }

    service {
      name = "grafana"
      port = "http"

      # Reached via the sandbox wildcard DNS (grey-cloud -> L4 LB -> Traefik
      # websecure, LE wildcard cert already covers grafana.<domain>).
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.grafana.entrypoints=web,websecure",
        "traefik.http.routers.grafana.rule=HostRegexp(`grafana.{domain:.+}`)",
        "traefik.http.routers.grafana.ruleSyntax=v2",
        "traefik.http.routers.grafana.priority=550",
      ]

      check {
        type     = "http"
        path     = "/api/health"
        interval = "20s"
        timeout  = "5s"
        port     = "http"
      }
    }

    task "grafana" {
      driver = "docker"

      config {
        image        = "grafana/grafana:11.6.0"
        network_mode = "host"

        volumes = [
          "local/provisioning/datasources:/etc/grafana/provisioning/datasources",
        ]
      }

      env {
        GF_SERVER_HTTP_PORT           = "$${NOMAD_PORT_http}"
        GF_SERVER_ROOT_URL            = "https://grafana.${domain_name}"
        GF_SECURITY_ADMIN_USER        = "admin"
        GF_SECURITY_ADMIN_PASSWORD    = "${admin_password}"
        GF_AUTH_ANONYMOUS_ENABLED     = "false"
        GF_USERS_ALLOW_SIGN_UP        = "false"
        GF_ANALYTICS_REPORTING_ENABLED = "false"
        GF_INSTALL_PLUGINS            = "grafana-clickhouse-datasource"
        GF_PATHS_DATA                 = "$${NOMAD_ALLOC_DIR}/data/grafana"
      }

      template {
        destination = "local/provisioning/datasources/datasources.yaml"
        data        = <<EOT
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki.service.consul:${loki_port}
    isDefault: true
    editable: false
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    access: proxy
    editable: false
    jsonData:
      host: clickhouse.service.consul
      port: ${clickhouse_port}
      protocol: native
      defaultDatabase: ${clickhouse_database}
      username: ${clickhouse_username}
    secureJsonData:
      password: ${clickhouse_password}
EOT
      }

      resources {
        memory = 512
        cpu    = 500
      }
    }
  }
}
