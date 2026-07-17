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

resource "random_password" "volume_token_key" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = [length, special]
  }
}

locals {
  redis_port          = 6379
  ingress_port        = 8080
  nomad_port          = 4646
  clickhouse_port     = 9000
  clickhouse_database = "default"
  loki_port           = 3100
  logs_proxy_port     = 30006
  otel_collector_port = 4317

  auth_provider_config = {
    jwt = []
  }

  clickhouse_connection_string = var.clickhouse_cluster_size > 0 ? "clickhouse://${module.init.clickhouse.username}:${module.init.clickhouse.password}@clickhouse.service.consul:${local.clickhouse_port}/${local.clickhouse_database}" : ""

  # The Nomad jobspec template renders each entry as `${key} = "${value}"`,
  # so values that themselves contain `"` characters (like a JSON blob)
  # must have those quotes pre-escaped to produce valid HCL.
  api_env_vars = merge({
    ENVIRONMENT                    = var.environment
    GIN_MODE                       = "release"
    DOMAIN_NAME                    = var.domain_name
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
    AZURE_ACR_LOGIN_SERVER       = module.init.acr_login_server
    AZURE_DOCKER_REPOSITORY_NAME = module.init.custom_environments_repository_name
  }, var.orchestrator_env_vars)

  template_manager_env_vars = merge({
    CONSUL_TOKEN                 = module.init.cluster.consul_acl_token
    ARTIFACTS_REGISTRY_PROVIDER  = "AZURE_ACR"
    STORAGE_PROVIDER             = "AzureBucket"
    AZURE_STORAGE_ACCOUNT        = module.init.storage_account_name
    AZURE_CLIENT_ID              = module.init.identity_client_id
    AZURE_ACR_LOGIN_SERVER       = module.init.acr_login_server
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
  }, var.template_manager_env_vars)
}

# ----------------------------------------------------------------------------
# TODO(azure): compute + Nomad wiring. These are later chunks and are NOT part
# of this foundation. When implemented they live at:
#   ./nomad-cluster  -> VMSS-based Nomad/Consul cluster (mirrors provider-aws/nomad-cluster)
#   ./nomad          -> Nomad jobspecs (mirrors provider-aws/nomad)
# They consume module.init.* (identity, storage containers, ACR, Key Vault) and
# the local.*_env_vars maps defined above.
#
# module "cluster" {
#   source = "./nomad-cluster"
#   ...
# }
#
# module "nomad" {
#   source = "./nomad"
#   ...
#   api_env_vars              = local.api_env_vars
#   api_db_migrator_env_vars  = local.api_db_migrator_env_vars
#   client_proxy_env_vars     = local.client_proxy_env_vars
#   orchestrator_env_vars     = local.orchestrator_env_vars
#   template_manager_env_vars = local.template_manager_env_vars
# }
# ----------------------------------------------------------------------------

