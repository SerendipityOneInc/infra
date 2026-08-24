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
          "local/provisioning/dashboards:/etc/grafana/provisioning/dashboards",
          "local/provisioning/alerting:/etc/grafana/provisioning/alerting",
          "local/dashboards:/var/lib/grafana/dashboards",
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
    uid: loki
    access: proxy
    url: http://loki.service.consul:${loki_port}
    isDefault: true
    editable: false
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    uid: clickhouse
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
  - name: E2B Postgres
    type: postgres
    uid: e2bpg
    access: proxy
    url: ${pg_host}:5432
    user: grafana_ro
    editable: false
    jsonData:
      database: e2b
      sslmode: require
      postgresVersion: 1500
      maxOpenConns: 4
    secureJsonData:
      password: ${pg_ro_password}
  - name: Azure Monitor
    type: grafana-azure-monitor-datasource
    uid: azuremonitor
    access: proxy
    editable: false
    jsonData:
      azureAuthType: clientsecret
      tenantId: ${azure_monitor_tenant_id}
      clientId: ${azure_monitor_client_id}
      subscriptionId: ${azure_monitor_subscription_id}
      cloudName: azuremonitor
    secureJsonData:
      clientSecret: ${azure_monitor_client_secret}
EOT
      }


      template {
        destination = "local/provisioning/dashboards/provider.yaml"
        data        = <<EOT
apiVersion: 1
providers:
  - name: e2b
    folder: E2B
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOT
      }

      template {
        destination = "local/provisioning/alerting/template-manager-memory.yaml"
        data        = <<EOT
apiVersion: 1
groups:
  - orgId: 1
    name: Template manager
    folder: E2B
    interval: 1m
    rules:
      - uid: template-manager-memory-pressure
        title: Template manager memory pressure
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: clickhouse
            model:
              datasource:
                type: grafana-clickhouse-datasource
                uid: clickhouse
              editorType: sql
              format: 1
              intervalMs: 15000
              maxDataPoints: 600
              queryType: timeseries
              rawSql: "SELECT toStartOfMinute(TimeUnix) AS time, maxIf(Value, MetricName = 'e2b.infra.build_cache.cgroup.memory.current') / nullIf(maxIf(Value, MetricName = 'e2b.infra.build_cache.cgroup.memory.max'), 0) * 100 AS memory_pct FROM otel_metrics_gauge WHERE MetricName IN ('e2b.infra.build_cache.cgroup.memory.current', 'e2b.infra.build_cache.cgroup.memory.max') AND TimeUnix > now() - INTERVAL 10 MINUTE GROUP BY time HAVING maxIf(Value, MetricName = 'e2b.infra.build_cache.cgroup.memory.max') > 0 ORDER BY time"
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [85]
                    type: gt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: NoData
        execErrState: Error
        for: 10m
        annotations:
          description: "The template-manager cgroup has remained above 85% after cache eviction should have started at 75%. New builds are at risk of mmap memfd allocation failures."
          summary: "Template-manager memory reclaim is not restoring headroom"
        labels:
          service: template-manager
          severity: warning
EOT
      }

      template {
        destination = "local/provisioning/alerting/sandbox-healthcheck-failures.yaml"
        data        = <<EOT
apiVersion: 1
groups:
  - orgId: 1
    name: Sandbox failures
    folder: E2B
    interval: 1m
    rules:
      - uid: sandbox-healthcheck-failures
        title: Sandbox healthcheck failures
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: loki
            model:
              datasource:
                type: loki
                uid: loki
              editorMode: code
              expr: "count_over_time({service=\"orchestrator\"} | json | level=\"error\" |= \"healthcheck started failing\" [5m])"
              queryType: range
              intervalMs: 15000
              maxDataPoints: 43200
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [0]
                    type: gt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: OK
        execErrState: Error
        for: 0m
        annotations:
          description: "orchestrator logged at least one 'Sandbox healthcheck started failing' error in the last 5 minutes. 30-day baseline is ~5 occurrences total, so even a single hit is worth paging on."
          summary: "Sandbox(es) failing health checks"
        labels:
          service: orchestrator
          severity: critical
EOT
      }

      template {
        destination = "local/provisioning/alerting/template-build-failure-rate.yaml"
        data        = <<EOT
apiVersion: 1
groups:
  - orgId: 1
    name: Template build failures
    folder: E2B
    interval: 1m
    rules:
      - uid: template-build-failure-rate
        title: Template build failure rate
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: e2bpg
            model:
              datasource:
                type: grafana-postgresql-datasource
                uid: e2bpg
              editorMode: code
              rawQuery: true
              rawSql: "SELECT count(*) AS value FROM env_builds WHERE status_group = 'failed' AND finished_at > now() - interval '5 minutes'"
              format: table
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [1]
                    type: gt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: OK
        execErrState: Error
        for: 0m
        annotations:
          description: "At least 2 template builds failed (env_builds.status_group = 'failed') in the last 5 minutes. 30-day baseline is 20/382 (~5.2%) at low volume, so 2+ in one window is anomalous clustering."
          summary: "Template build failures clustering"
        labels:
          service: template-manager
          severity: critical
EOT
      }

      template {
        destination = "local/provisioning/alerting/notification-policies.yaml"
        data        = <<EOT
apiVersion: 1
policies:
  - orgId: 1
    receiver: grafana-default-email
    group_by: ["grafana_folder", "alertname"]
    routes:
      - receiver: PagerDuty
        object_matchers:
          - ["severity", "=", "critical"]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
        continue: false
EOT
      }

      template {
        destination = "local/provisioning/alerting/node-resource-pressure.yaml"
        data        = <<EOT
apiVersion: 1
groups:
  - orgId: 1
    name: Node resource pressure
    folder: E2B
    interval: 1m
    rules:
      - uid: node-cpu-pressure
        title: Node CPU pressure
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: clickhouse
            model:
              datasource:
                type: grafana-clickhouse-datasource
                uid: clickhouse
              editorType: sql
              format: 1
              intervalMs: 15000
              maxDataPoints: 600
              queryType: timeseries
              rawSql: "SELECT time, min(idle_pct) AS worst_idle_pct FROM (SELECT toStartOfMinute(TimeUnix) AS time, Attributes['host'] AS host, avg(Value) AS idle_pct FROM otel_metrics_gauge WHERE MetricName = 'nomad_client_host_cpu_idle' AND TimeUnix > now() - INTERVAL 10 MINUTE GROUP BY time, host) GROUP BY time ORDER BY time"
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [15]
                    type: lt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: OK
        execErrState: Error
        for: 10m
        annotations:
          description: "The worst client-pool node's CPU idle has stayed below 15% (i.e. busy above 85%) for 10 minutes. Check the E2B Cluster Nodes dashboard for which host."
          summary: "A node's CPU usage is above 85%"
        labels:
          service: orchestrator
          severity: warning

      - uid: node-memory-pressure
        title: Node memory pressure
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: clickhouse
            model:
              datasource:
                type: grafana-clickhouse-datasource
                uid: clickhouse
              editorType: sql
              format: 1
              intervalMs: 15000
              maxDataPoints: 600
              queryType: timeseries
              rawSql: "SELECT time, min(available_pct) AS worst_available_pct FROM (SELECT toStartOfMinute(TimeUnix) AS time, Attributes['host'] AS host, avgIf(Value, MetricName = 'nomad_client_host_memory_available') / nullIf(avgIf(Value, MetricName = 'nomad_client_host_memory_total'), 0) * 100 AS available_pct FROM otel_metrics_gauge WHERE MetricName IN ('nomad_client_host_memory_available', 'nomad_client_host_memory_total') AND TimeUnix > now() - INTERVAL 10 MINUTE GROUP BY time, host HAVING avgIf(Value, MetricName = 'nomad_client_host_memory_total') > 0) GROUP BY time ORDER BY time"
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [15]
                    type: lt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: OK
        execErrState: Error
        for: 10m
        annotations:
          description: "The worst client-pool node's available memory has stayed below 15% of total (i.e. used above 85%) for 10 minutes. Check the E2B Cluster Nodes dashboard for which host."
          summary: "A node's memory usage is above 85%"
        labels:
          service: orchestrator
          severity: warning

      - uid: node-disk-pressure
        title: Node disk pressure
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: clickhouse
            model:
              datasource:
                type: grafana-clickhouse-datasource
                uid: clickhouse
              editorType: sql
              format: 1
              intervalMs: 15000
              maxDataPoints: 600
              queryType: timeseries
              rawSql: "SELECT time, min(available_pct) AS worst_available_pct FROM (SELECT toStartOfMinute(TimeUnix) AS time, concat(Attributes['host'], ' ', Attributes['disk']) AS disk, avgIf(Value, MetricName = 'nomad_client_host_disk_available') / nullIf(avgIf(Value, MetricName = 'nomad_client_host_disk_size'), 0) * 100 AS available_pct FROM otel_metrics_gauge WHERE MetricName IN ('nomad_client_host_disk_available', 'nomad_client_host_disk_size') AND TimeUnix > now() - INTERVAL 10 MINUTE AND Attributes['disk'] NOT LIKE '%loop%' GROUP BY time, disk HAVING avgIf(Value, MetricName = 'nomad_client_host_disk_size') > 0) GROUP BY time ORDER BY time"
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [15]
                    type: lt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: OK
        execErrState: Error
        for: 10m
        annotations:
          description: "The worst client-pool disk's available space has stayed below 15% of size (i.e. used above 85%) for 10 minutes. Loop devices (/dev/loop*, squashfs/snap mounts) are excluded -- they read as permanently 0% available and are not real capacity. Check the E2B Cluster Nodes dashboard for which host/disk."
          summary: "A disk's usage is above 85%"
        labels:
          service: orchestrator
          severity: warning
EOT
      }

      template {
        destination = "local/provisioning/alerting/team-concurrency-pressure.yaml"
        data        = <<EOT
apiVersion: 1
groups:
  - orgId: 1
    name: Team concurrency pressure
    folder: E2B
    interval: 1m
    rules:
      - uid: team-concurrency-pressure
        title: Team sandbox concurrency pressure
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: clickhouse
            model:
              datasource:
                type: grafana-clickhouse-datasource
                uid: clickhouse
              editorType: sql
              format: 1
              intervalMs: 15000
              maxDataPoints: 600
              queryType: timeseries
              rawSql: "SELECT time, max(concurrency_pct) AS worst_concurrency_pct FROM (SELECT toStartOfMinute(timestamp) AS time, team_id, avg(value) / 300 * 100 AS concurrency_pct FROM team_metrics_gauge WHERE metric_name = 'e2b.team.sandbox.running' AND timestamp > now() - INTERVAL 10 MINUTE GROUP BY time, team_id) GROUP BY time ORDER BY time"
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [85]
                    type: gt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: OK
        execErrState: Error
        for: 10m
        annotations:
          description: "The busiest team's live sandbox count has stayed above 85% of the tiers.concurrent_instances cap (300) for 10 minutes -- they are close to being rate-limited and the tier likely needs review. Check the E2B Tenants dashboard for which team."
          summary: "A team is approaching its concurrent sandbox limit"
        labels:
          service: api
          severity: warning
EOT
      }

      template {
        destination = "local/provisioning/alerting/client-pool-capacity.yaml"
        data        = <<EOT
apiVersion: 1
groups:
  - orgId: 1
    name: Client pool capacity
    folder: E2B
    interval: 1m
    rules:
      - uid: client-pool-capacity-ceiling
        title: Client pool sustained near capacity
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: azuremonitor
            model:
              datasource:
                type: grafana-azure-monitor-datasource
                uid: azuremonitor
              queryType: Azure Monitor
              subscription: ${azure_monitor_subscription_id}
              azureMonitor:
                metricNamespace: e2b
                metricName: SlotsUsedPct
                aggregation: Maximum
                timeGrain: PT1M
                region: centralus
              resources:
                - subscription: ${azure_monitor_subscription_id}
                  resourceGroup: ${azure_monitor_resource_group}
                  resourceName: ${client_vmss_name}
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource:
                type: __expr__
                uid: __expr__
              expression: A
              reducer: last
              refId: B
              type: reduce
          - refId: C
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [90]
                    type: gt
                  operator:
                    type: and
                  query:
                    params: [C]
                  reducer:
                    params: []
                    type: last
                  type: query
              datasource:
                type: __expr__
                uid: __expr__
              expression: B
              refId: C
              type: threshold
        noDataState: OK
        execErrState: Error
        for: 15m
        annotations:
          description: "Pool-wide max SlotsUsedPct has stayed above 90% for 15 minutes -- longer than the 5m scale-out cooldown, so autoscale either cannot add capacity (VMSS already at its max instance count) or is not keeping up. New sandbox placements are at risk of failing."
          summary: "Client pool sustained near/at capacity, autoscale may not be keeping up"
        labels:
          service: orchestrator
          severity: critical
EOT
      }

      template {
        destination = "local/dashboards/cluster-nodes.json"
        left_delimiter  = "[["
        right_delimiter = "]]"
        data            = <<EOT
{
 "uid": "e2b-cluster-nodes",
 "title": "E2B Cluster Nodes",
 "timezone": "browser",
 "schemaVersion": 39,
 "refresh": "1m",
 "time": {
  "from": "now-6h",
  "to": "now"
 },
 "panels": [
  {
   "title": "Node available memory (GiB)",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 0,
    "y": 0
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(TimeUnix) AS time, Attributes['host'] AS host, avg(Value)/1073741824 AS avail_gib FROM otel_metrics_gauge WHERE MetricName = 'nomad_client_host_memory_available' AND $__timeFilter(TimeUnix) GROUP BY time, host ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "title": "Node CPU idle (%)",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 12,
    "y": 0
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(TimeUnix) AS time, Attributes['host'] AS host, avg(Value) AS idle_pct FROM otel_metrics_gauge WHERE MetricName = 'nomad_client_host_cpu_idle' AND $__timeFilter(TimeUnix) GROUP BY time, host ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "title": "Alloc memory usage by task (GiB)",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 0,
    "y": 9
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(TimeUnix) AS time, Attributes['task'] AS task, max(Value)/1073741824 AS used_gib FROM otel_metrics_gauge WHERE MetricName = 'nomad_client_allocs_memory_usage' AND $__timeFilter(TimeUnix) GROUP BY time, task ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "title": "Node disk available (GiB)",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 12,
    "y": 9
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(TimeUnix) AS time, concat(Attributes['host'], ' ', Attributes['disk']) AS disk, avg(Value)/1073741824 AS avail_gib FROM otel_metrics_gauge WHERE MetricName = 'nomad_client_host_disk_available' AND $__timeFilter(TimeUnix) GROUP BY time, disk ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "title": "Template-manager cgroup memory (%)",
   "description": "Build-cache eviction starts at 75%. The alert fires after usage remains above 85% for 10 minutes.",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 0,
    "y": 18
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": {
     "unit": "percent",
     "min": 0,
     "max": 100,
     "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 75 }, { "color": "red", "value": 85 } ] }
    },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(TimeUnix) AS time, maxIf(Value, MetricName = 'e2b.infra.build_cache.cgroup.memory.current') / nullIf(maxIf(Value, MetricName = 'e2b.infra.build_cache.cgroup.memory.max'), 0) * 100 AS memory_pct FROM otel_metrics_gauge WHERE MetricName IN ('e2b.infra.build_cache.cgroup.memory.current', 'e2b.infra.build_cache.cgroup.memory.max') AND $__timeFilter(TimeUnix) GROUP BY time HAVING maxIf(Value, MetricName = 'e2b.infra.build_cache.cgroup.memory.max') > 0 ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "title": "Template-manager cgroup memory breakdown (GiB)",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 12,
    "y": 18
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": { "unit": "gbytes" },
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(TimeUnix) AS time, replaceOne(MetricName, 'e2b.infra.build_cache.cgroup.memory.', '') AS kind, max(Value)/1073741824 AS used_gib FROM otel_metrics_gauge WHERE startsWith(MetricName, 'e2b.infra.build_cache.cgroup.memory.') AND MetricName != 'e2b.infra.build_cache.cgroup.memory.max' AND $__timeFilter(TimeUnix) GROUP BY time, kind ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  }
 ]
}
EOT
      }

      template {
        destination = "local/dashboards/sandboxes.json"
        left_delimiter  = "[["
        right_delimiter = "]]"
        data            = <<EOT
{
 "uid": "e2b-sandboxes",
 "title": "E2B Sandboxes",
 "timezone": "browser",
 "schemaVersion": 39,
 "refresh": "1m",
 "templating": {
  "list": [
   {
    "name": "sandbox_id",
    "label": "Sandbox",
    "type": "query",
    "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
    "query": "SELECT DISTINCT sandbox_id FROM sandbox_metrics_gauge WHERE timestamp > now() - INTERVAL 6 HOUR ORDER BY sandbox_id",
    "refresh": 2,
    "includeAll": true,
    "allValue": ".*",
    "multi": true,
    "current": { "text": ["All"], "value": ["$__all"] },
    "sort": 1
   }
  ]
 },
 "time": {
  "from": "now-6h",
  "to": "now"
 },
 "panels": [
  {
   "id": 100,
   "type": "row",
   "title": "Summary — aggregate over selected sandboxes",
   "collapsed": false,
   "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 },
   "panels": []
  },
  {
   "id": 1,
   "title": "Active sandboxes",
   "description": "Distinct sandboxes reporting metrics in each interval.",
   "type": "timeseries",
   "gridPos": { "h": 8, "w": 8, "x": 0, "y": 1 },
   "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
   "fieldConfig": {
    "defaults": { "unit": "none", "decimals": 0, "custom": { "fillOpacity": 10, "showPoints": "never" } },
    "overrides": []
   },
   "options": { "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true } },
   "targets": [
    {
     "refId": "A",
     "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(timestamp) AS time, uniqExact(sandbox_id) AS sandboxes FROM sandbox_metrics_gauge WHERE $__timeFilter(timestamp) AND match(sandbox_id, '^($$${sandbox_id:regex})$') GROUP BY time ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "id": 2,
   "title": "Total vCPU — used vs allocated",
   "description": "used = sum over sandboxes of cpu.used% x cpu.total. allocated = sum of cpu.total. Compare against the node's physical vCPU count to see oversubscription.",
   "type": "timeseries",
   "gridPos": { "h": 8, "w": 8, "x": 8, "y": 1 },
   "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
   "fieldConfig": {
    "defaults": { "unit": "none", "decimals": 2, "custom": { "fillOpacity": 10, "showPoints": "never" } },
    "overrides": [
     { "matcher": { "id": "byName", "options": "vcpu_allocated" },
       "properties": [ { "id": "custom.fillOpacity", "value": 0 }, { "id": "custom.lineStyle", "value": { "fill": "dash", "dash": [10, 10] } } ] }
    ]
   },
   "options": { "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true } },
   "targets": [
    {
     "refId": "A",
     "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT time, sum(used) AS vcpu_used, sum(total) AS vcpu_allocated FROM (SELECT $__timeInterval(timestamp) AS time, sandbox_id, avgIf(value, metric_name = 'e2b.sandbox.cpu.total') AS total, avgIf(value, metric_name = 'e2b.sandbox.cpu.used') / 100 * total AS used FROM sandbox_metrics_gauge WHERE metric_name IN ('e2b.sandbox.cpu.used', 'e2b.sandbox.cpu.total') AND $__timeFilter(timestamp) AND match(sandbox_id, '^($$${sandbox_id:regex})$') GROUP BY time, sandbox_id) GROUP BY time ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "id": 3,
   "title": "Total RAM — used vs allocated",
   "description": "used = sum of ram.used. allocated = sum of ram.total (what the templates asked for). The gap is memory paid for but not touched.",
   "type": "timeseries",
   "gridPos": { "h": 8, "w": 8, "x": 16, "y": 1 },
   "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
   "fieldConfig": {
    "defaults": { "unit": "bytes", "custom": { "fillOpacity": 10, "showPoints": "never" } },
    "overrides": [
     { "matcher": { "id": "byName", "options": "ram_allocated" },
       "properties": [ { "id": "custom.fillOpacity", "value": 0 }, { "id": "custom.lineStyle", "value": { "fill": "dash", "dash": [10, 10] } } ] }
    ]
   },
   "options": { "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true } },
   "targets": [
    {
     "refId": "A",
     "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT time, sum(used) AS ram_used, sum(total) AS ram_allocated FROM (SELECT $__timeInterval(timestamp) AS time, sandbox_id, maxIf(value, metric_name = 'e2b.sandbox.ram.used') AS used, maxIf(value, metric_name = 'e2b.sandbox.ram.total') AS total FROM sandbox_metrics_gauge WHERE metric_name IN ('e2b.sandbox.ram.used', 'e2b.sandbox.ram.total') AND $__timeFilter(timestamp) AND match(sandbox_id, '^($$${sandbox_id:regex})$') GROUP BY time, sandbox_id) GROUP BY time ORDER BY time",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "id": 101,
   "type": "row",
   "title": "Per-sandbox detail — one line per sandbox",
   "collapsed": false,
   "gridPos": { "h": 1, "w": 24, "x": 0, "y": 9 },
   "panels": []
  },
  {
   "id": 4,
   "title": "CPU used (%) per sandbox",
   "description": "Percentage of the sandbox's own vCPU allocation. Pick specific sandboxes in the Sandbox variable — with All selected this draws one line per active sandbox.",
   "type": "timeseries",
   "gridPos": { "h": 9, "w": 12, "x": 0, "y": 10 },
   "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
   "fieldConfig": {
    "defaults": { "unit": "percent", "min": 0, "custom": { "fillOpacity": 0, "showPoints": "never" } },
    "overrides": []
   },
   "options": { "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true } },
   "transformations": [
    { "id": "partitionByValues", "options": { "fields": ["sandbox_id"], "keepFields": false, "naming": { "asLabels": false } } }
   ],
   "targets": [
    {
     "refId": "A",
     "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(timestamp) AS time, sandbox_id, avg(value) AS cpu_pct FROM sandbox_metrics_gauge WHERE metric_name = 'e2b.sandbox.cpu.used' AND $__timeFilter(timestamp) AND match(sandbox_id, '^($$${sandbox_id:regex})$') GROUP BY time, sandbox_id ORDER BY time, sandbox_id",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "id": 5,
   "title": "RAM used per sandbox",
   "description": "ram.used per sandbox. Does not include page cache (see ram.cache).",
   "type": "timeseries",
   "gridPos": { "h": 9, "w": 12, "x": 12, "y": 10 },
   "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
   "fieldConfig": {
    "defaults": { "unit": "bytes", "min": 0, "custom": { "fillOpacity": 0, "showPoints": "never" } },
    "overrides": []
   },
   "options": { "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true } },
   "transformations": [
    { "id": "partitionByValues", "options": { "fields": ["sandbox_id"], "keepFields": false, "naming": { "asLabels": false } } }
   ],
   "targets": [
    {
     "refId": "A",
     "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(timestamp) AS time, sandbox_id, max(value) AS ram_used FROM sandbox_metrics_gauge WHERE metric_name = 'e2b.sandbox.ram.used' AND $__timeFilter(timestamp) AND match(sandbox_id, '^($$${sandbox_id:regex})$') GROUP BY time, sandbox_id ORDER BY time, sandbox_id",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "id": 6,
   "title": "Disk used per sandbox",
   "description": "disk.used per sandbox — the writable overlay on the node's local NVMe.",
   "type": "timeseries",
   "gridPos": { "h": 9, "w": 12, "x": 0, "y": 19 },
   "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
   "fieldConfig": {
    "defaults": { "unit": "bytes", "min": 0, "custom": { "fillOpacity": 0, "showPoints": "never" } },
    "overrides": []
   },
   "options": { "legend": { "displayMode": "list", "placement": "bottom", "showLegend": true } },
   "transformations": [
    { "id": "partitionByValues", "options": { "fields": ["sandbox_id"], "keepFields": false, "naming": { "asLabels": false } } }
   ],
   "targets": [
    {
     "refId": "A",
     "datasource": { "type": "grafana-clickhouse-datasource", "uid": "clickhouse" },
     "editorType": "sql", "queryType": "timeseries",
     "rawSql": "SELECT $__timeInterval(timestamp) AS time, sandbox_id, max(value) AS disk_used FROM sandbox_metrics_gauge WHERE metric_name = 'e2b.sandbox.disk.used' AND $__timeFilter(timestamp) AND match(sandbox_id, '^($$${sandbox_id:regex})$') GROUP BY time, sandbox_id ORDER BY time, sandbox_id",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "id": 7,
   "title": "Recent sandbox logs",
   "type": "logs",
   "gridPos": { "h": 9, "w": 12, "x": 12, "y": 19 },
   "datasource": { "type": "loki", "uid": "loki" },
   "fieldConfig": { "defaults": {}, "overrides": [] },
   "targets": [
    {
     "refId": "A",
     "datasource": { "type": "loki", "uid": "loki" },
     "expr": "{source=\"logs-collector\"}"
    }
   ]
  }
 ]
}
EOT
      }


      template {
        destination = "local/dashboards/tenants.json"
        left_delimiter  = "[["
        right_delimiter = "]]"
        data            = <<EOT
{
 "uid": "e2b-tenants",
 "title": "E2B Tenants",
 "timezone": "browser",
 "schemaVersion": 39,
 "refresh": "5m",
 "time": {
  "from": "now-24h",
  "to": "now"
 },
 "panels": [
  {
   "title": "Teams",
   "type": "table",
   "gridPos": {
    "h": 8,
    "w": 24,
    "x": 0,
    "y": 0
   },
   "datasource": {
    "type": "grafana-postgresql-datasource",
    "uid": "e2bpg"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-postgresql-datasource",
      "uid": "e2bpg"
     },
     "rawSql": "SELECT t.name, t.slug, t.tier, t.email, t.is_banned OR t.is_blocked AS blocked, (SELECT count(*) FROM team_api_keys k WHERE k.team_id = t.id) AS api_keys, t.created_at FROM teams t ORDER BY t.created_at",
     "format": "table",
     "rawQuery": true,
     "editorMode": "code"
    }
   ]
  },
  {
   "title": "Active sandboxes by team",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 0,
    "y": 8
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "rawSql": "SELECT $__timeInterval(timestamp) AS time, team_id, uniqExact(sandbox_id) AS sandboxes FROM sandbox_metrics_gauge WHERE $__timeFilter(timestamp) GROUP BY time, team_id ORDER BY time",
     "editorType": "sql",
     "queryType": "timeseries",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "title": "Sandbox CPU by team (avg %)",
   "type": "timeseries",
   "gridPos": {
    "h": 9,
    "w": 12,
    "x": 12,
    "y": 8
   },
   "datasource": {
    "type": "grafana-clickhouse-datasource",
    "uid": "clickhouse"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-clickhouse-datasource",
      "uid": "clickhouse"
     },
     "rawSql": "SELECT $__timeInterval(timestamp) AS time, team_id, avg(value) AS cpu_pct FROM sandbox_metrics_gauge WHERE metric_name = 'e2b.sandbox.cpu.used' AND $__timeFilter(timestamp) GROUP BY time, team_id ORDER BY time",
     "editorType": "sql",
     "queryType": "timeseries",
     "format": 1,
     "pluginVersion": "4.20.0"
    }
   ]
  },
  {
   "title": "Templates",
   "type": "table",
   "gridPos": {
    "h": 8,
    "w": 24,
    "x": 0,
    "y": 17
   },
   "datasource": {
    "type": "grafana-postgresql-datasource",
    "uid": "e2bpg"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-postgresql-datasource",
      "uid": "e2bpg"
     },
     "rawSql": "SELECT e.id AS template_id, (SELECT string_agg(a.alias, ', ') FROM env_aliases a WHERE a.env_id = e.id AND a.namespace IS NULL) AS global_alias, (SELECT string_agg(a.namespace || '/' || a.alias, ', ') FROM env_aliases a WHERE a.env_id = e.id AND a.namespace IS NOT NULL) AS team_alias, e.public, t.name AS team, e.created_at FROM envs e JOIN teams t ON t.id = e.team_id ORDER BY e.created_at DESC",
     "format": "table",
     "rawQuery": true,
     "editorMode": "code"
    }
   ]
  },
  {
   "title": "Recent builds",
   "type": "table",
   "gridPos": {
    "h": 8,
    "w": 24,
    "x": 0,
    "y": 25
   },
   "datasource": {
    "type": "grafana-postgresql-datasource",
    "uid": "e2bpg"
   },
   "fieldConfig": {
    "defaults": {},
    "overrides": []
   },
   "targets": [
    {
     "refId": "A",
     "datasource": {
      "type": "grafana-postgresql-datasource",
      "uid": "e2bpg"
     },
     "rawSql": "SELECT b.env_id AS template_id, b.status, b.vcpu, b.ram_mb, b.created_at, b.finished_at FROM env_builds b ORDER BY b.created_at DESC LIMIT 50",
     "format": "table",
     "rawQuery": true,
     "editorMode": "code"
    }
   ]
  }
 ]
}
EOT
      }

      resources {
        memory = 512
        cpu    = 500
      }
    }
  }
}
