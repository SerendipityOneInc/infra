# ============================================================================
# Azure Nomad jobspecs. Mirrors iac/provider-aws/nomad but adapts the two things
# that are provider-specific: (1) artifact delivery of the raw Go binaries, and
# (2) container image references (ACR instead of ECR/Artifact Registry).
#
# Scope: the compute-plane jobs (api, client-proxy, orchestrator,
# template-manager, autoscaler, ingress, redis), the in-cluster observability
# tier (clickhouse, loki, logs-collector, otel-collector — the shared modules
# gained an azure provider branch), grafana, and dashboard-api
# (platform-managed mode). Not deployed: otel-collector-nomad-server and
# docker-reverse-proxy (both serve flows this deployment doesn't use).
# ============================================================================

# ---
# Artifact delivery. go-getter has no native azblob getter, so we build a plain
# https:: source pointing at the versioned "<name>.<commit_sha>" blob in the
# fc-env-pipeline container, authenticated with a read-only container SAS.
#
#   https::https://<account>.blob.core.windows.net/<container>/<name>.<sha>?<sas>
#
# The <sha> in the blob name is the cache-buster (AWS uses ?etag=, GCP ?version=)
# and the SAS query provides auth. The SAS start/expiry are fixed (see variables)
# so the signature is deterministic and the source only changes when commit_sha
# changes.
# ---

# Re-read the storage account (created by module.init) to obtain a connection
# string for SAS generation without threading a key output out of init.
data "azurerm_storage_account" "primary" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

data "azurerm_storage_account_blob_container_sas" "fc_env_pipeline" {
  connection_string = data.azurerm_storage_account.primary.primary_connection_string
  container_name    = var.fc_env_pipeline_container_name
  https_only        = true

  start  = var.sas_start
  expiry = var.sas_expiry

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = true
  }
}

locals {
  # primary_blob_endpoint already carries a trailing slash, e.g.
  # "https://<account>.blob.core.windows.net/".
  fc_env_pipeline_base = "${data.azurerm_storage_account.primary.primary_blob_endpoint}${var.fc_env_pipeline_container_name}"

  # The SAS data source may or may not include a leading "?"; normalise to
  # exactly one.
  sas_query = "?${trimprefix(data.azurerm_storage_account_blob_container_sas.fc_env_pipeline.sas, "?")}"

  orchestrator_artifact_source     = "https::${local.fc_env_pipeline_base}/orchestrator.${var.commit_sha}${local.sas_query}"
  template_manager_artifact_source = "https::${local.fc_env_pipeline_base}/template-manager.${var.commit_sha}${local.sas_query}"
  apm_plugin_artifact_source       = "https::${local.fc_env_pipeline_base}/nomad-nodepool-apm.${var.commit_sha}${local.sas_query}"

  # ACR image refs. Repository names already include "<prefix>core/<component>".
  api_image          = "${var.acr_login_server}/${var.api_repository_name}:${var.image_tag}"
  db_migrator_image  = "${var.acr_login_server}/${var.db_migrator_repository_name}:${var.image_tag}"
  client_proxy_image = "${var.acr_login_server}/${var.client_proxy_repository_name}:${var.image_tag}"
}

# Its already set up in Nomad server config, but from there its taken only for
# newly created clusters so we need to make sure its applied here to existing.
resource "nomad_scheduler_config" "config" {
  memory_oversubscription_enabled = true
}

module "ingress" {
  source = "../../modules/job-ingress"

  ingress_count         = var.ingress_count
  ingress_port          = var.ingress_port
  ingress_internal_port = var.ingress_internal_port

  traefik_config_files = var.traefik_config_files

  node_pool     = var.api_node_pool
  update_stanza = var.api_cluster_size > 1

  nomad_token  = var.nomad_acl_token
  consul_token = var.consul_acl_token

  otel_collector_grpc_endpoint = "localhost:${var.otel_collector_grpc_port}"

  # TLS-terminating websecure entrypoint for the sandbox data plane (L4 LB path).
  # Traefik self-manages the LE wildcard certs (Cloudflare DNS-01) for both the
  # public and internal domains, and persists them on a host volume.
  tls_enabled      = var.dataplane_tls_enabled
  acme_email       = var.acme_email
  cf_dns_api_token = var.cf_dns_api_token
  acme_domains = [
    { main = var.domain_name, sans = ["*.${var.domain_name}"] },
    { main = var.internal_domain_name, sans = ["*.${var.internal_domain_name}"] },
  ]
}

module "client_proxy" {
  source = "../../modules/job-client-proxy"

  update_stanza      = var.api_cluster_size > 1
  client_proxy_count = var.client_proxy_count

  node_pool = var.api_node_pool

  image        = local.client_proxy_image
  job_env_vars = var.client_proxy_env_vars

  # Reach client-proxy over h2c via Traefik's websecure entrypoint (L4 LB path)
  # so bidirectional HTTP/2 (PTY) survives to envd.
  secure_entrypoint = var.dataplane_tls_enabled
}

module "api" {
  source = "../../modules/job-api"

  update_stanza      = var.api_cluster_size > 1
  node_pool          = var.api_node_pool
  prevent_colocation = var.api_cluster_size > 2
  count_instances    = var.api_cluster_size

  memory_mb = var.api_memory_mb
  cpu_count = var.api_cpu_count

  port_name                = "api"
  port_number              = var.api_port
  api_internal_grpc_port   = var.api_internal_grpc_port
  api_docker_image         = local.api_image
  db_migrator_docker_image = local.db_migrator_image
  job_env_vars             = var.api_env_vars
  db_migrator_env_vars     = var.api_db_migrator_env_vars
}

module "orchestrator" {
  source = "../../modules/job-orchestrator"

  node_pool  = var.orchestrator_node_pool
  port       = var.orchestrator_port
  proxy_port = var.orchestrator_proxy_port

  environment           = var.environment
  artifact_source       = local.orchestrator_artifact_source
  orchestrator_checksum = var.commit_sha
  job_env_vars          = var.orchestrator_env_vars
}

module "template_manager" {
  source = "../../modules/job-template-manager"

  update_stanza = var.build_cluster_size > 1
  node_pool     = var.build_node_pool

  port = var.template_manager_port

  artifact_source = local.template_manager_artifact_source
  job_env_vars    = var.template_manager_env_vars
  memory_max_mb   = var.template_manager_memory_max_mb

  nomad_addr  = "https://nomad.${var.domain_name}"
  nomad_token = var.nomad_acl_token
}

module "template_manager_autoscaler" {
  source = "../../modules/job-template-manager-autoscaler"
  count  = var.build_cluster_size > 1 ? 1 : 0

  node_pool                  = var.api_node_pool
  nomad_token                = var.nomad_acl_token
  apm_plugin_artifact_source = local.apm_plugin_artifact_source
}

# Publishes per-node sandbox slot utilisation to Azure Monitor as a custom
# metric, which is what the client pool's autoscale rule scales on. Azure's
# platform metrics cannot see either binding limit: the per-node sandbox count
# cap is a count, and sandbox memory comes out of a hugepage pool that is
# preallocated at boot (so consuming it never moves Available Memory Bytes).
resource "nomad_job" "slots_metrics_publisher" {
  count = var.slots_publisher_enabled ? 1 : 0

  jobspec = templatefile("${path.module}/jobs/slots-metrics-publisher.hcl", {
    node_pool              = var.api_node_pool
    api_url                = var.slots_publisher_api_url
    admin_token            = var.slots_publisher_admin_token
    vmss_resource_id       = var.slots_publisher_vmss_resource_id
    region                 = var.slots_publisher_region
    node_prefix            = var.slots_publisher_node_prefix
    max_sandboxes_per_node = var.slots_publisher_max_sandboxes_per_node
    interval_seconds       = var.slots_publisher_interval_seconds
    reclaim_enabled        = var.slots_publisher_reclaim_enabled
    reclaim_below_pct      = var.slots_publisher_reclaim_below_pct
    reclaim_min_nodes      = var.slots_publisher_reclaim_min_nodes
    scale_out_pct          = coalesce(var.slots_publisher_scale_out_pct, 70)
  })
}

module "redis" {
  source = "../../modules/job-redis"
  count  = var.redis_managed ? 0 : 1

  node_pool   = var.api_node_pool
  port_number = var.redis_port
  port_name   = "redis"
}

# ---
# Observability. No Grafana Cloud account is wired for this deployment, so
# only the in-cluster legs run: ClickHouse stores sandbox/host metrics (read
# back by the API), Loki stores logs shipped by logs-collector (vector), and
# otel-collector routes e2b.* OTLP metrics into ClickHouse via an Azure
# override config (the shared default config hard-wires Grafana exporters).
# ---

module "clickhouse" {
  source = "../../modules/job-clickhouse"
  count  = var.clickhouse_server_count > 0 ? 1 : 0

  provider_name = "azure"

  node_pool             = var.clickhouse_node_pool
  job_constraint_prefix = var.clickhouse_job_constraint_prefix
  server_count          = var.clickhouse_server_count

  server_secret = var.clickhouse_server_secret
  cpu_count     = 2
  memory_mb     = 8192

  clickhouse_database = var.clickhouse_database
  clickhouse_username = var.clickhouse_username
  clickhouse_password = var.clickhouse_password
  billing_username    = var.billing_clickhouse_username
  billing_password    = var.billing_clickhouse_password
  billing_enabled     = true
  clickhouse_port     = var.clickhouse_port

  clickhouse_metrics_port = var.clickhouse_metrics_port
  otel_exporter_endpoint  = "http://localhost:${var.otel_collector_grpc_port}"

  # Backup (clickhouse-backup azblob remote storage).
  backup_bucket       = var.clickhouse_backups_container_name
  azblob_account_name = var.storage_account_name
  azblob_account_key  = var.storage_account_primary_key

  clickhouse_migrator_image = var.clickhouse_migrator_image
}

module "loki" {
  source = "../../modules/job-loki"
  count  = var.loki_container_name != "" ? 1 : 0

  provider_name = "azure"

  node_pool = var.api_node_pool

  prevent_colocation = false
  bucket_name        = var.loki_container_name

  azure_storage_account_name = var.storage_account_name
  azure_user_assigned_id     = var.identity_client_id

  loki_port = var.loki_port
}

module "logs_collector" {
  source = "../../modules/job-logs-collector"
  count  = var.loki_container_name != "" ? 1 : 0

  loki_endpoint = "http://loki.service.consul:${var.loki_port}"

  vector_health_port = var.logs_health_proxy_port
  vector_api_port    = var.logs_proxy_port

  # No Grafana Cloud: vector's grafana sink is gated on a non-empty endpoint.
  grafana_logs_user     = ""
  grafana_logs_endpoint = ""
  grafana_api_key       = ""
}

module "otel_collector" {
  source = "../../modules/job-otel-collector"

  provider_name = "azure"

  otel_collector_grpc_port = var.otel_collector_grpc_port

  # Dummy values — the default config (which needs them) is fully replaced by
  # the override below.
  grafana_otel_collector_token = "unused"
  grafana_otlp_url             = "unused"
  grafana_username             = "unused"

  otel_collector_config_override = templatefile("${path.module}/configs/otel-collector-azure.yaml", {
    clickhouse_host     = "clickhouse.service.consul"
    clickhouse_port     = var.clickhouse_port
    clickhouse_database = var.clickhouse_database
    clickhouse_username = var.clickhouse_username
    clickhouse_password = var.clickhouse_password
  })
}

# In-cluster Grafana over the Loki + ClickHouse datasources (no Grafana Cloud
# account for this deployment). Reached at grafana.<domain> through the
# sandbox wildcard path; nomad's own operational view stays the Nomad UI.
resource "nomad_job" "grafana" {
  count = var.grafana_enabled ? 1 : 0

  jobspec = templatefile("${path.module}/jobs/grafana.hcl", {
    node_pool           = var.api_node_pool
    domain_name         = var.domain_name
    admin_password      = var.grafana_admin_password
    loki_port           = var.loki_port
    clickhouse_port     = var.clickhouse_port
    clickhouse_database = var.clickhouse_database
    clickhouse_username = var.clickhouse_username
    clickhouse_password = var.clickhouse_password
    pg_host             = var.grafana_pg_host
    pg_ro_password      = var.grafana_pg_readonly_password

    azure_monitor_client_id       = var.grafana_azure_monitor_client_id
    azure_monitor_client_secret   = var.grafana_azure_monitor_client_secret
    azure_monitor_tenant_id       = var.grafana_azure_monitor_tenant_id
    azure_monitor_subscription_id = var.grafana_azure_monitor_subscription_id
    azure_monitor_resource_group  = var.grafana_azure_monitor_resource_group
    # Matches SLOTS_NODE_PREFIX / SLOTS_VMSS_RESOURCE_ID in the
    # slots-metrics-publisher job. Client pool only -- SlotsUsedPct is not
    # published for the build pool (it scales on plain CPU today).
    client_vmss_name = "e2b-orch-client"
  })
}

# Dashboard API: team/user provisioning + admin endpoints. This deployment
# runs it in platform-managed mode (ADMIN_TOKEN only): the Ory values are
# non-empty placeholders to satisfy startup validation, and no user-facing
# OAuth is wired — see the provider README/runbook.
module "dashboard_api" {
  source = "../../modules/job-dashboard-api"
  count  = var.dashboard_api_count > 0 ? 1 : 0

  count_instances = var.dashboard_api_count
  node_pool       = var.api_node_pool
  update_stanza   = var.dashboard_api_count > 1

  image = "${var.acr_login_server}/${var.dashboard_api_repository_name}:${var.image_tag}"

  job_env_vars = var.dashboard_api_env_vars
}

module "billing" {
  source = "../../modules/job-billing"
  count  = var.billing_gateway_count > 0 ? 1 : 0

  count_instances = var.billing_gateway_count
  node_pool       = var.api_node_pool
  update_stanza   = var.billing_gateway_count > 1
  image           = "${var.acr_login_server}/${var.billing_gateway_repository_name}:${var.image_tag}"
  job_env_vars    = var.billing_gateway_env_vars
}
