job "billing" {
  node_pool = "${node_pool}"
  priority  = 80

  group "gateway" {
    count = ${count}

    restart {
      interval = "5m"
      attempts = 5
      delay    = "10s"
      mode     = "delay"
    }

    network {
      port "http" {}
    }

    service {
      name = "billing"
      port = "http"
      task = "gateway"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.billing.entrypoints=web",
        "traefik.http.routers.billing.rule=HostRegexp(`billing.{domain:.+}`)",
        "traefik.http.routers.billing.ruleSyntax=v2",
        "traefik.http.routers.billing.priority=1000"
      ]

      check {
        type     = "http"
        name     = "ready"
        path     = "/ready"
        interval = "10s"
        timeout  = "3s"
        port     = "http"
      }
    }

%{ if update_stanza }
    update {
      max_parallel     = 1
      canary           = 1
      min_healthy_time = "10s"
      healthy_deadline = "5m"
      progress_deadline = "6m"
      auto_promote     = true
    }
%{ endif }

    task "gateway" {
      driver       = "docker"
      kill_timeout = "15s"
      kill_signal  = "SIGTERM"

      resources {
        memory     = 128
        memory_max = 256
        cpu        = 200
      }

      env {
        PORT = "$${NOMAD_PORT_http}"
%{ for key, value in job_env_vars ~}
        ${key} = "${value}"
%{ endfor ~}
      }

      config {
        network_mode = "host"
        image        = "${image_name}"
        ports        = ["http"]
      }
    }
  }
}
