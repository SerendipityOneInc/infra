terraform {
  required_version = ">= 1.5.0"

  backend "azurerm" {
    key = "terraform/orchestration/state"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "4.52.5"
    }

    nomad = {
      source  = "hashicorp/nomad"
      version = "2.1.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.8.1"
    }

    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }

  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "cloudflare" {
  api_token = module.init.cloudflare.token
}

provider "nomad" {
  address      = "https://nomad.${var.domain_name}"
  secret_id    = module.init.cluster.nomad_acl_token
  consul_token = module.init.cluster.consul_acl_token
}

data "azurerm_client_config" "current" {}

# The deployment resource group. Created by terraform if it does not already
# exist (the tfstate backend lives in a separate resource group managed by the
# Makefile's `init` target).
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

module "init" {
  source = "./init"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  storage_account_name = var.storage_account_name
  acr_name             = var.acr_name
  key_vault_name       = var.key_vault_name

  tenant_id          = var.tenant_id
  deployer_object_id = data.azurerm_client_config.current.object_id

  postgres_connection_string = var.postgres_connection_string
  remote_repository_enabled  = var.remote_repository_enabled

  tags = var.tags
}

module "network" {
  source = "./modules/network"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  # Co-locate on an existing VNet (e.g. the shared zooclaw-dev-vnet) to reach the
  # private-endpoint Postgres + JuiceFS meta directly; empty = dedicated VNet.
  existing_vnet_name           = var.existing_vnet_name
  existing_vnet_resource_group = var.existing_vnet_resource_group
  cluster_subnet_cidr          = var.cluster_subnet_cidr
  services_subnet_cidr         = var.services_subnet_cidr
  key_vault_name               = var.key_vault_name

  # The App Gateway forwards default (api./sandbox/docker.) + grpc-api. traffic to
  # the in-cluster Traefik ingress entrypoint, which then does dynamic host-based
  # routing. Must match the job-ingress ingress_port below.
  ingress_backend_port = local.ingress_port

  # LE cert issued/renewed into KV by module.acmebot; the gateway auto-rotates.
  public_cert_name = local.public_cert_name

  # In-VNet path: private frontend + Private DNS zone for the internal domain,
  # served with its own LE cert. See locals.internal_domain_name.
  internal_domain_name = local.internal_domain_name
  internal_cert_name   = local.internal_cert_name

  domain_name = var.domain_name

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Cloudflare DNS. The Application Gateway v2 (L7) terminates TLS and host-routes:
# nomad. -> Nomad server pool (4646), grpc-api. -> grpc pool, and everything else
# (sandbox wildcard, api., docker.) -> the client-proxy ingress pool. All
# control-plane hostnames are proxied through Cloudflare (Full SSL mode: the
# gateway presents a self-signed origin cert). The per-sandbox wildcard is
# DNS-only and points straight at the gateway frontend IP.
# ----------------------------------------------------------------------------
module "cloudflare" {
  source = "./modules/cloudflare"

  domain_name    = var.domain_name
  lb_frontend_ip = module.network.appgw_public_ip
  # Sandbox wildcard points at the L4 data-plane LB (HTTP/2/PTY); control-plane
  # hosts stay on the App Gateway.
  wildcard_ip = module.network.dataplane_public_ip
}

# ----------------------------------------------------------------------------
# Automated public TLS: keyvault-acmebot (timer-driven Azure Function) issues
# and renews the Let's Encrypt cert for <domain> + *.<domain> via Cloudflare
# DNS-01 straight into Key Vault. The App Gateway references the KV secret
# WITHOUT a version and polls KV (~4h), so rotation needs no human and no
# terraform apply. First issuance is a one-time API call (see runbook):
#   curl -X POST "https://<func>.azurewebsites.net/api/certificate" \
#     -H "x-functions-key: <api_key>" -H "Content-Type: application/json" \
#     -d '{"CertificateName":"<name>","DnsNames":["<domain>","*.<domain>"]}'
# ----------------------------------------------------------------------------
module "acmebot" {
  source  = "shibayan/keyvault-acmebot/azurerm"
  version = "3.1.4"

  app_base_name       = "${trimsuffix(var.prefix, "-")}-acmebot"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  mail_address        = var.acmebot_mail_address
  vault_uri           = module.init.key_vault_uri

  cloudflare = {
    api_token = module.init.cloudflare.token
  }

  additional_tags = var.tags
}

# The acmebot function's managed identity manages certificates in our KV
# (RBAC-mode vault, so a role assignment rather than an access policy).
resource "azurerm_role_assignment" "acmebot_kv_certificates" {
  scope                = module.init.key_vault_id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = module.acmebot.principal_id
}

locals {
  # KV certificate name for the public wildcard cert (dots are not allowed).
  public_cert_name = replace(var.domain_name, ".", "-")

  # Internal-only domain for in-VNet consumers (ECA-986 bots): first label gets
  # an "-int" suffix (sandbox2.yesy.dev -> sandbox2-int.yesy.dev). A REAL
  # subdomain of the public zone — so Let's Encrypt can issue for it via
  # DNS-01 — but resolvable ONLY through the Private DNS zone linked to the
  # VNet (never published in public DNS): traffic goes straight to the App
  # Gateway's private frontend, skipping Cloudflare and the public internet.
  internal_domain_name = replace(var.domain_name, "/^([^.]+)/", "$1-int")
  internal_cert_name   = replace(local.internal_domain_name, ".", "-")
}

# One-time first issuance, encoded in terraform so a fresh environment needs no
# manual API call. Idempotent: acmebot upserts by certificate name; renewals
# afterwards are handled by acmebot's own timer (no terraform involved).
resource "null_resource" "acmebot_first_issuance" {
  for_each = {
    (local.public_cert_name)   = var.domain_name
    (local.internal_cert_name) = local.internal_domain_name
  }

  triggers = {
    certificate = each.key
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      FUNC="func-${trimsuffix(var.prefix, "-")}-acmebot"
      FKEY=$(az functionapp keys list -g ${azurerm_resource_group.main.name} -n "$FUNC" --query "functionKeys.default" -o tsv)
      BASE="https://$FUNC.azurewebsites.net/api"
      # Skip if the cert already exists (re-runs must not burn LE duplicate quota).
      if curl -sf -m 30 "$BASE/certificates" -H "x-functions-key: $FKEY" | grep -q '"name":"${each.key}"'; then
        echo "certificate ${each.key} already present"; exit 0
      fi
      curl -sf -m 180 -X POST "$BASE/certificate" \
        -H "x-functions-key: $FKEY" -H "Content-Type: application/json" \
        -d '{"CertificateName":"${each.key}","DnsNames":["${each.value}","*.${each.value}"]}'
      # Issuance is async (202): wait until the cert lands in Key Vault so that
      # anything referencing the KV secret (App Gateway) applies after it exists.
      for i in $(seq 1 30); do
        sleep 10
        if curl -sf -m 30 "$BASE/certificates" -H "x-functions-key: $FKEY" | grep -q '"name":"${each.key}"'; then
          echo "certificate ${each.key} issued"; exit 0
        fi
      done
      echo "timed out waiting for certificate ${each.key}" >&2; exit 1
    EOT
  }

  depends_on = [azurerm_role_assignment.acmebot_kv_certificates]
}

resource "random_password" "volume_token_key" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = [length, special]
  }
}

locals {
  # Nomad node pool names (mirror provider-aws locals). The client (Firecracker
  # host) pool is named "default" for backwards-compat with the orchestrator.
  api_pool_name          = "api"
  client_pool_name       = "default"
  build_pool_name        = "build"
  clickhouse_pool_name   = "clickhouse"
  clickhouse_jobs_prefix = "clickhouse"
}

locals {
  redis_port            = 6379
  ingress_port          = 8080
  juicefs_volume_type   = "juicefs"
  juicefs_mount_path    = "/mnt/persistent-volume-types/juicefs"
  ingress_internal_port = 9435
  nomad_port            = 4646
  clickhouse_port       = 9000
  clickhouse_database   = "default"
  loki_port             = 3100
  logs_proxy_port       = 30006
  otel_collector_port   = 4317
  template_manager_port = 5008
  api_port              = 80

  auth_provider_config = {
    jwt = []
  }

  clickhouse_connection_string = var.clickhouse_cluster_size > 0 ? "clickhouse://${module.init.clickhouse.username}:${module.init.clickhouse.password}@clickhouse.service.consul:${local.clickhouse_port}/${local.clickhouse_database}" : ""

  # The Nomad jobspec template renders each entry as `${key} = "${value}"`,
  # so values that themselves contain `"` characters (like a JSON blob)
  # must have those quotes pre-escaped to produce valid HCL.
  api_env_vars = merge({
    ENVIRONMENT = var.environment
    GIN_MODE    = "release"
    DOMAIN_NAME = var.domain_name
    # Volume type new volumes default to (JuiceFS). Empty if no volume mounted.
    DEFAULT_PERSISTENT_VOLUME_TYPE = length(var.juicefs_volumes) > 0 ? local.juicefs_volume_type : ""
    NOMAD_TOKEN                    = module.init.cluster.nomad_acl_token
    ORCHESTRATOR_PORT              = tostring(var.orchestrator_port)
    API_INTERNAL_GRPC_PORT         = tostring(var.api_internal_grpc_port)
    ADMIN_TOKEN                    = module.init.admin_token
    SANDBOX_ACCESS_TOKEN_HASH_SEED = module.init.sandbox_access_token_hash_seed
    AUTH_PROVIDER_CONFIG           = replace(jsonencode(local.auth_provider_config), "\"", "\\\"")

    POSTGRES_CONNECTION_STRING   = module.init.postgres_connection_string
    DB_MAX_OPEN_CONNECTIONS      = tostring(var.db_max_open_connections)
    DB_MIN_IDLE_CONNECTIONS      = tostring(var.db_min_idle_connections)
    AUTH_DB_CONNECTION_STRING    = module.init.postgres_connection_string
    AUTH_DB_MAX_OPEN_CONNECTIONS = tostring(var.auth_db_max_open_connections)
    AUTH_DB_MIN_IDLE_CONNECTIONS = tostring(var.auth_db_min_idle_connections)

    LOKI_URL                     = "http://loki.service.consul:${local.loki_port}"
    CLICKHOUSE_CONNECTION_STRING = local.clickhouse_connection_string

    # Redis is deployed as the in-cluster `redis` Nomad job (registered in Consul
    # as redis.service.consul). The api requires it; without REDIS_URL the api
    # treats redis as disabled and fatals ("redis is disabled"). Mirrors the GCP
    # api_env_vars (self-hosted single-node redis, no managed cluster URL).
    REDIS_URL       = "redis.service.consul:${local.redis_port}"
    REDIS_POOL_SIZE = "40"

    LOGS_COLLECTOR_ADDRESS       = "http://localhost:${local.logs_proxy_port}"
    OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:${local.otel_collector_port}"

    LAUNCH_DARKLY_API_KEY = module.init.launch_darkly_api_key
    # This is here just because it is required in some part of our code which is transitively imported
    TEMPLATE_BUCKET_NAME = "skip"

    VOLUME_TOKEN_ISSUER           = var.domain_name
    VOLUME_TOKEN_SIGNING_KEY      = "HMAC:${base64encode(random_password.volume_token_key.result)}"
    VOLUME_TOKEN_SIGNING_KEY_NAME = "e2b-volume-token-key"
    VOLUME_TOKEN_DURATION         = "1h"
    VOLUME_TOKEN_SIGNING_METHOD   = "HS256"
  }, var.api_env_vars)

  api_db_migrator_env_vars = merge({
    POSTGRES_CONNECTION_STRING = module.init.postgres_connection_string
  }, var.api_db_migrator_env_vars)

  client_proxy_env_vars = merge({
    ENVIRONMENT                  = var.environment
    OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:${local.otel_collector_port}"
    LOGS_COLLECTOR_ADDRESS       = "http://localhost:${local.logs_proxy_port}"
    # Used by in-cluster client-proxy to call API ResumeSandbox over gRPC.
    API_INTERNAL_GRPC_ADDRESS = "api-internal-grpc.service.consul:${var.api_internal_grpc_port}"
    LAUNCH_DARKLY_API_KEY     = module.init.launch_darkly_api_key
    # client-proxy also requires Redis; without REDIS_URL it fatals with
    # "redis is disabled". Point at the in-cluster redis Nomad job.
    REDIS_URL       = "redis.service.consul:${local.redis_port}"
    REDIS_POOL_SIZE = "40"
  }, var.client_proxy_env_vars)

  orchestrator_env_vars = merge({
    LOGS_COLLECTOR_ADDRESS       = "http://localhost:${local.logs_proxy_port}"
    ENVIRONMENT                  = var.environment
    ENVD_TIMEOUT                 = var.envd_timeout
    TEMPLATE_BUCKET_NAME         = module.init.fc_template_container_name
    OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:${local.otel_collector_port}"
    ALLOW_SANDBOX_INTERNAL_CIDRS = var.allow_sandbox_internal_cidrs
    CLICKHOUSE_CONNECTION_STRING = local.clickhouse_connection_string
    GIN_MODE                     = "release"
    CONSUL_TOKEN                 = module.init.cluster.consul_acl_token
    DOMAIN_NAME                  = var.domain_name
    SHARED_CHUNK_CACHE_PATH      = ""
    ORCHESTRATOR_SERVICES        = "orchestrator"
    PROVIDER                     = "azure"
    BUILD_CACHE_BUCKET_NAME      = module.init.fc_build_cache_container_name
    LAUNCH_DARKLY_API_KEY        = module.init.launch_darkly_api_key

    # Azure object storage: az://<account>/<container>, resolved via the
    # user-assigned Managed Identity (DefaultAzureCredential / AZURE_CLIENT_ID).
    STORAGE_PROVIDER      = "AzureBucket"
    AZURE_STORAGE_ACCOUNT = module.init.storage_account_name
    AZURE_CLIENT_ID       = module.init.identity_client_id
    # NOTE: the Go artifacts-registry package does not yet implement an Azure ACR
    # backend (only GCP_ARTIFACTS / AWS_ECR / Local). This value is a placeholder
    # for when that lands and is threaded once module.nomad is implemented.
    ARTIFACTS_REGISTRY_PROVIDER  = "AZURE_ACR"
    AZURE_CONTAINER_REGISTRY     = module.init.acr_login_server
    AZURE_DOCKER_REPOSITORY_NAME = module.init.custom_environments_repository_name

    # JuiceFS persistent-volume type -> host mount (client nodes mount it in
    # start-client.sh at the same path). The orchestrator NFS proxy exports
    # subtrees from here; the volume type name matches DEFAULT_PERSISTENT_VOLUME_TYPE.
    PERSISTENT_VOLUME_MOUNTS = length(var.juicefs_volumes) > 0 ? "${local.juicefs_volume_type}:${local.juicefs_mount_path}" : ""
  }, var.orchestrator_env_vars)

  template_manager_env_vars = merge({
    CONSUL_TOKEN                 = module.init.cluster.consul_acl_token
    ARTIFACTS_REGISTRY_PROVIDER  = "AZURE_ACR"
    STORAGE_PROVIDER             = "AzureBucket"
    AZURE_STORAGE_ACCOUNT        = module.init.storage_account_name
    AZURE_CLIENT_ID              = module.init.identity_client_id
    AZURE_CONTAINER_REGISTRY     = module.init.acr_login_server
    AZURE_DOCKER_REPOSITORY_NAME = module.init.custom_environments_repository_name
    API_SECRET                   = module.init.api_secret
    ENVIRONMENT                  = var.environment
    DOMAIN_NAME                  = var.domain_name
    TEMPLATE_BUCKET_NAME         = module.init.fc_template_container_name
    BUILD_CACHE_BUCKET_NAME      = module.init.fc_build_cache_container_name
    OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:${local.otel_collector_port}"
    LOGS_COLLECTOR_ADDRESS       = "http://localhost:${local.logs_proxy_port}"
    ORCHESTRATOR_SERVICES        = "template-manager"
    CLICKHOUSE_CONNECTION_STRING = local.clickhouse_connection_string
    GIN_MODE                     = "release"
    LAUNCH_DARKLY_API_KEY        = module.init.launch_darkly_api_key
    # Azure uploads route through the HMAC proxy endpoint on this server (the
    # e2b SDK cannot bare-PUT to an Azure SAS URL — mandatory x-ms-blob-type
    # header). Traefik routes api.<domain>/upload here (job-template-manager
    # service tags), so the URL works for both the public and internal domains.
    LOCAL_UPLOAD_BASE_URL = "https://api.${var.domain_name}"
  }, var.template_manager_env_vars)
}

# ----------------------------------------------------------------------------
# Compute plane: VMSS-based Nomad/Consul cluster (mirrors provider-aws/
# nomad-cluster). Consumes module.init.* (identity, storage containers, ACR)
# and module.network.* (cluster subnet, LB backend pool).
# ----------------------------------------------------------------------------

module "cluster" {
  source = "./nomad-cluster"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location

  # JuiceFS persistent volumes: client/build nodes mount these at boot (token
  # from Key Vault via the node MI). mount_path lines up with the orchestrator
  # PERSISTENT_VOLUME_MOUNTS env above.
  key_vault_name  = var.key_vault_name
  juicefs_volumes = var.juicefs_volumes

  identity_id        = module.init.identity_id
  identity_client_id = module.init.identity_client_id

  cluster_subnet_id = module.network.cluster_subnet_id
  # App Gateway host-routing backends (mirrors GCP, where the ingress + grpc
  # backend services target the api instance group):
  #   * nomad.<domain>    -> control-server pool (Nomad servers) on 4646
  #   * grpc-api.<domain> -> api pool (gRPC)
  #   * everything else   -> api pool (the client-proxy/ingress runs on the api
  #     node pool; it reaches sandboxes on the orch client pool internally, so the
  #     orch client/build pools are NOT App Gateway backends).
  api_appgw_backend_pool_ids    = [module.network.ingress_backend_pool_id, module.network.grpc_backend_pool_id]
  api_lb_backend_pool_ids       = module.network.dataplane_backend_pool_ids
  client_appgw_backend_pool_ids = []
  server_appgw_backend_pool_ids = [module.network.nomad_backend_pool_id]

  nomad_acl_token_secret          = module.init.cluster.nomad_acl_token
  consul_acl_token_secret         = module.init.cluster.consul_acl_token
  consul_dns_request_token_secret = module.init.cluster.consul_dns_request_token
  consul_gossip_encryption_key    = module.init.cluster.consul_gossip_encryption_key

  storage_account_name           = module.init.storage_account_name
  setup_container_name           = module.init.setup_container_name
  fc_env_pipeline_container_name = module.init.fc_env_pipeline_container_name
  fc_kernels_container_name      = module.init.fc_kernels_container_name
  fc_versions_container_name     = module.init.fc_versions_container_name
  fc_busybox_container_name      = module.init.fc_busybox_container_name
  acr_login_server               = module.init.acr_login_server

  control_server_cluster_size = var.control_server_cluster_size
  control_server_machine_type = var.control_server_machine_type
  control_server_image_id     = var.control_server_image_id != "" ? var.control_server_image_id : var.cluster_image_id

  api_node_pool_name = local.api_pool_name
  api_cluster_size   = var.api_cluster_size
  api_machine_type   = var.api_server_machine_type
  api_image_id       = var.api_image_id != "" ? var.api_image_id : var.cluster_image_id

  client_node_pool_name               = local.client_pool_name
  client_cluster_size                 = var.client_cluster_size
  client_machine_type                 = var.client_server_machine_type
  client_image_id                     = var.client_image_id != "" ? var.client_image_id : var.cluster_image_id
  client_node_labels                  = var.client_node_labels
  client_server_nested_virtualization = var.client_server_nested_virtualization
  client_max_instances                = var.client_max_instances
  client_scale_out_memory_free_bytes  = var.client_scale_out_memory_free_bytes
  client_scale_in_memory_free_bytes   = var.client_scale_in_memory_free_bytes

  build_node_pool_name               = local.build_pool_name
  build_cluster_size                 = var.build_cluster_size
  build_machine_type                 = var.build_server_machine_type
  build_image_id                     = var.build_image_id != "" ? var.build_image_id : var.cluster_image_id
  build_node_labels                  = var.build_node_labels
  build_server_nested_virtualization = var.build_server_nested_virtualization
  build_max_instances                = var.build_max_instances

  clickhouse_node_pool_name        = local.clickhouse_pool_name
  clickhouse_cluster_size          = var.clickhouse_cluster_size
  clickhouse_machine_type          = var.clickhouse_server_machine_type
  clickhouse_image_id              = var.clickhouse_image_id != "" ? var.clickhouse_image_id : var.cluster_image_id
  clickhouse_job_constraint_prefix = local.clickhouse_jobs_prefix

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Nomad jobspecs (mirrors provider-aws/nomad). Renders the shared iac/modules/
# job-* modules with Azure inputs: ACR image refs, the local.*_env_vars maps,
# and https:: artifact sources (SAS-authed Blob) for the raw Go binaries.
# ----------------------------------------------------------------------------

module "nomad" {
  source = "./nomad"

  domain_name         = var.domain_name
  environment         = var.environment
  resource_group_name = azurerm_resource_group.main.name

  # Sandbox data-plane TLS: Traefik terminates + self-manages LE wildcard certs
  # for both domains, reached via the L4 LB (App Gateway can't carry PTY's h2).
  dataplane_tls_enabled = true
  internal_domain_name  = local.internal_domain_name
  acme_email            = var.acmebot_mail_address
  cf_dns_api_token      = module.init.cloudflare.token

  nomad_acl_token  = module.init.cluster.nomad_acl_token
  consul_acl_token = module.init.cluster.consul_acl_token

  api_node_pool          = local.api_pool_name
  orchestrator_node_pool = local.client_pool_name
  build_node_pool        = local.build_pool_name

  api_cluster_size   = var.api_cluster_size
  build_cluster_size = var.build_cluster_size

  # Artifact delivery (raw Go binaries over SAS-authed HTTPS).
  storage_account_name           = module.init.storage_account_name
  fc_env_pipeline_container_name = module.init.fc_env_pipeline_container_name
  commit_sha                     = var.commit_sha

  # ACR image refs.
  acr_login_server             = module.init.acr_login_server
  image_tag                    = var.image_tag
  api_repository_name          = module.init.api_repository_name
  db_migrator_repository_name  = module.init.db_migrator_repository_name
  client_proxy_repository_name = module.init.client_proxy_repository_name

  # Ingress.
  ingress_count         = var.ingress_count
  ingress_port          = local.ingress_port
  ingress_internal_port = local.ingress_internal_port
  traefik_config_files  = var.traefik_config_files

  # API.
  api_port                 = local.api_port
  api_internal_grpc_port   = var.api_internal_grpc_port
  api_env_vars             = local.api_env_vars
  api_db_migrator_env_vars = local.api_db_migrator_env_vars

  # Client proxy.
  client_proxy_count    = var.client_proxy_count
  client_proxy_env_vars = local.client_proxy_env_vars

  # Orchestrator.
  orchestrator_port       = var.orchestrator_port
  orchestrator_proxy_port = var.orchestrator_proxy_port
  orchestrator_env_vars   = local.orchestrator_env_vars

  # Template manager.
  template_manager_port     = local.template_manager_port
  template_manager_env_vars = local.template_manager_env_vars

  # Redis.
  redis_managed = var.redis_managed
  redis_port    = local.redis_port

  # Telemetry.
  otel_collector_grpc_port = local.otel_collector_port

  # Observability (ClickHouse + Loki + logs/otel collectors; in-cluster only —
  # no Grafana Cloud account, see nomad/main.tf).
  clickhouse_node_pool             = local.clickhouse_pool_name
  clickhouse_job_constraint_prefix = local.clickhouse_jobs_prefix
  clickhouse_server_count          = var.clickhouse_cluster_size
  clickhouse_username              = module.init.clickhouse.username
  clickhouse_password              = module.init.clickhouse.password
  clickhouse_server_secret         = module.init.clickhouse.server_secret
  clickhouse_port                  = local.clickhouse_port
  clickhouse_database              = local.clickhouse_database
  clickhouse_migrator_image        = "${module.init.acr_login_server}/${module.init.clickhouse_migrator_repository_name}:${var.image_tag}"

  clickhouse_backups_container_name = module.init.clickhouse_backups_container_name
  storage_account_primary_key       = module.init.storage_account_primary_key

  loki_port           = local.loki_port
  loki_container_name = module.init.loki_container_name
  identity_client_id  = module.init.identity_client_id

  grafana_enabled        = true
  grafana_admin_password = module.init.grafana_admin_password
}

