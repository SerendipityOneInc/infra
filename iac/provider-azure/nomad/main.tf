# ============================================================================
# Azure Nomad jobspecs. Mirrors iac/provider-aws/nomad but adapts the two things
# that are provider-specific: (1) artifact delivery of the raw Go binaries, and
# (2) container image references (ACR instead of ECR/Artifact Registry).
#
# Scope: the provider-agnostic compute-plane jobs (api, client-proxy,
# orchestrator, template-manager, autoscaler, ingress, redis). The observability
# + analytics tier (job-otel-collector, job-otel-collector-nomad-server,
# job-loki, job-clickhouse) is intentionally NOT instantiated here: those shared
# modules hard-validate provider_name in {"gcp","aws"} and reject "azure", and
# module.init does not yet output the Grafana secrets / ClickHouse backup
# credentials they need. They are deferred until those shared modules gain an
# Azure branch. See the repo report / PR description.
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
}

module "client_proxy" {
  source = "../../modules/job-client-proxy"

  update_stanza      = var.api_cluster_size > 1
  client_proxy_count = var.client_proxy_count

  node_pool = var.api_node_pool

  image        = local.client_proxy_image
  job_env_vars = var.client_proxy_env_vars
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

module "redis" {
  source = "../../modules/job-redis"
  count  = var.redis_managed ? 0 : 1

  node_pool   = var.api_node_pool
  port_number = var.redis_port
  port_name   = "redis"
}
