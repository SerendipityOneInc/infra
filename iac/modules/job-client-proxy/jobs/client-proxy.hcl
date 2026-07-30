job "client-proxy" {
  node_pool = "${node_pool}"
  priority  = 80

  group "client-proxy" {
    // If the service fails, try up to 2 restarts in 10 minutes
    // if another restart happens, it will trigger reschedule
    restart {
      attempts = 2
      interval = "10m"
      delay    = "10s"
      mode     = "fail"
    }

    // If too many restarts happens on one node,
    // try to place it on another with exponential backoff
    reschedule {
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "10m"
      unlimited      = true
    }

    count = ${count}

    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    network {
      port "proxy" {
        static = "${proxy_port}"
      }

      port "health" {
        static = "${health_port}"
      }
    }

    service {
      name = "client-proxy"
      port = "proxy"

      // This route is fallback (with lowest priority) to catch all requests as it serves sandbox traffic with dynamic subdomains
      tags = [
        "traefik.enable=true",

        "traefik.http.routers.client-proxy.entrypoints=${entrypoints}",
        "traefik.http.routers.client-proxy.rule=PathPrefix(`/`)",
        "traefik.http.routers.client-proxy.ruleSyntax=v2",
        "traefik.http.routers.client-proxy.priority=100",
        # Bind explicitly: Traefik only infers the service when exactly one is
        # declared here, and the websocket router below adds a second.
        "traefik.http.routers.client-proxy.service=client-proxy",

        "traefik.http.services.client-proxy.loadbalancer.server.port=$${NOMAD_PORT_proxy}",
        # h2c on the secure path so bidirectional HTTP/2 (PTY) survives to envd.
        "traefik.http.services.client-proxy.loadbalancer.server.scheme=${backend_scheme}",
%{ if backend_scheme == "h2c" ~}

        # HTTP/2 cannot carry an HTTP/1.1 Upgrade, so with an h2c backend a
        # WebSocket handshake dies at this hop — which is what makes noVNC
        # (computer-use live view) and CDP-from-outside unreachable.
        #
        # Send only upgrade requests over HTTP/1.1, on a higher-priority router
        # pointing at the same port. client-proxy serves both protocols there
        # (ConfigureH2C wraps an ordinary HTTP/1.1 server), and its transport to
        # the sandbox sets ForceAttemptHTTP2=false, so ReverseProxy carries the
        # upgrade the rest of the way.
        #
        # No ruleSyntax here: this router uses v3 syntax, where the matcher is
        # HeaderRegexp. Under the v2 syntax the routers above declare it would
        # be HeadersRegexp, and the mismatch silently fails to parse.
        #
        # The match must not catch h2c upgrades or PTY breaks: those carry
        # `Upgrade: h2c` with `Connection: HTTP2-Settings`, so anchoring on the
        # websocket token keeps them on the h2c router.
        "traefik.http.routers.client-proxy-ws.entrypoints=${entrypoints}",
        "traefik.http.routers.client-proxy-ws.rule=PathPrefix(`/`) && HeaderRegexp(`Upgrade`, `(?i)^websocket`)",
        "traefik.http.routers.client-proxy-ws.priority=200",
        "traefik.http.routers.client-proxy-ws.service=client-proxy-ws",

        "traefik.http.services.client-proxy-ws.loadbalancer.server.port=$${NOMAD_PORT_proxy}",
        "traefik.http.services.client-proxy-ws.loadbalancer.server.scheme=http"
%{ endif ~}
      ]

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "3s"
        timeout  = "3s"
        port     = "health"
      }
    }

%{ if update_stanza }
    # An update stanza to enable rolling updates of the service
    update {
      # The number of instances that can be updated at the same time
      max_parallel     = ${update_max_parallel}
      # Number of extra instances that can be spawn before killing the old one
      canary           = ${update_max_parallel}
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

    task "start" {
      driver = "docker"
      # If we need more than 30s we will need to update the max_kill_timeout in nomad
      # https://developer.hashicorp.com/nomad/docs/configuration/client#max_kill_timeout
%{ if update_stanza }
      kill_timeout = "24h"
%{ endif }
      kill_signal  = "SIGTERM"

      resources {
        memory_max = ${memory_mb * 1.5}
        memory     = ${memory_mb}
        cpu        = ${cpu_count * 1000}
      }

      env {
        NODE_ID = "$${node.unique.id}"
        NODE_IP = "$${attr.unique.network.ip-address}"

        HEALTH_PORT = "$${NOMAD_PORT_health}"
        PROXY_PORT  = "$${NOMAD_PORT_proxy}"

%{ for key, value in job_env_vars ~}
        ${key} = "${value}"
%{ endfor ~}
      }

      config {
        network_mode = "host"
        image        = "${image}"
        ports        = ["proxy", "health"]
      }
    }
  }
}
