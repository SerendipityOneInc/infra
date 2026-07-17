# ---
# Key Vault. Mirrors the AWS Secrets Manager set (secrets.tf + secrets-cluster.tf).
# RBAC authorization is used: the cluster identity gets Secrets User (see main.tf)
# and the terraform principal gets Secrets Officer so it can seed the secrets.
# ---
resource "azurerm_key_vault" "main" {
  name                       = local.key_vault_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

  tags = var.tags
}

resource "azurerm_role_assignment" "deployer_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.deployer_object_id
}

# ---
# Cluster tokens (Consul gossip, Nomad/Consul ACL tokens). Mirrors secrets-cluster.tf.
# ---
resource "random_uuid" "nomad_acl_token" {}

resource "random_uuid" "consul_acl_token" {}

resource "random_uuid" "consul_dns_request_token" {}

resource "random_id" "consul_gossip_encryption_key" {
  byte_length = 32
}

resource "azurerm_key_vault_secret" "cluster" {
  name         = "${var.prefix}cluster"
  key_vault_id = azurerm_key_vault.main.id
  value = jsonencode({
    NOMAD_ACL_TOKEN              = random_uuid.nomad_acl_token.result,
    CONSUL_ACL_TOKEN             = random_uuid.consul_acl_token.result,
    CONSUL_DNS_REQUEST_TOKEN     = random_uuid.consul_dns_request_token.result,
    CONSUL_GOSSIP_ENCRYPTION_KEY = random_id.consul_gossip_encryption_key.b64_std,
  })

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ---
# ClickHouse
# ---
resource "random_password" "clickhouse_password" {
  length  = 32
  special = false
}

resource "random_password" "clickhouse_server_secret" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "clickhouse" {
  name         = "${var.prefix}clickhouse"
  key_vault_id = azurerm_key_vault.main.id
  value = jsonencode({
    CLICKHOUSE_USERNAME = "e2b",
    CLICKHOUSE_PASSWORD = random_password.clickhouse_password.result,
    SERVER_SECRET       = random_password.clickhouse_server_secret.result,
  })

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ---
# Grafana (placeholder, populated out of band)
# ---
resource "azurerm_key_vault_secret" "grafana" {
  name         = "${var.prefix}grafana"
  key_vault_id = azurerm_key_vault.main.id
  value = jsonencode({
    API_KEY                  = " ",
    OTLP_URL                 = " ",
    OTEL_COLLECTOR_TOKEN     = " ",
    USERNAME                 = " ",
    LOGS_USER                = " ",
    LOGS_URL                 = " ",
    LOGS_COLLECTOR_API_TOKEN = " ",
  })

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ---
# API secret
# ---
resource "random_password" "api_secret" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "api_secret" {
  name         = "${var.prefix}api-secret"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.api_secret.result

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ---
# API admin token
# ---
resource "random_password" "admin_token" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "admin_token" {
  name         = "${var.prefix}admin-token"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.admin_token.result

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ---
# Sandbox access token hash seed
# ---
resource "random_password" "sandbox_access_token_hash_seed" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "sandbox_access_token_hash_seed" {
  name         = "${var.prefix}sandbox-access-token-hash-seed"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.sandbox_access_token_hash_seed.result

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ---
# PostgreSQL connection string (seeded from a variable; edit out of band)
# ---
resource "azurerm_key_vault_secret" "postgres_connection_string" {
  name         = "${var.prefix}postgres-connection-string"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.postgres_connection_string

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

data "azurerm_key_vault_secret" "postgres_connection_string" {
  name         = azurerm_key_vault_secret.postgres_connection_string.name
  key_vault_id = azurerm_key_vault.main.id
}

# ---
# Cloudflare API token (placeholder, populated out of band)
# ---
resource "azurerm_key_vault_secret" "cloudflare_api_token" {
  name         = "${var.prefix}cloudflare-api-token"
  key_vault_id = azurerm_key_vault.main.id
  value        = " "

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

data "azurerm_key_vault_secret" "cloudflare_api_token" {
  name         = azurerm_key_vault_secret.cloudflare_api_token.name
  key_vault_id = azurerm_key_vault.main.id
}

# ---
# LaunchDarkly API key (placeholder, populated out of band)
# ---
resource "azurerm_key_vault_secret" "launch_darkly_api_key" {
  name         = "${var.prefix}launch-darkly-api-key"
  key_vault_id = azurerm_key_vault.main.id
  value        = " "

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

data "azurerm_key_vault_secret" "launch_darkly_api_key" {
  name         = azurerm_key_vault_secret.launch_darkly_api_key.name
  key_vault_id = azurerm_key_vault.main.id
}

# ---
# Redis (placeholders, populated out of band)
# ---
resource "azurerm_key_vault_secret" "redis_cluster_url" {
  name         = "${var.prefix}redis-cluster-url"
  key_vault_id = azurerm_key_vault.main.id
  value        = " "

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "redis_tls_ca_base64" {
  name         = "${var.prefix}redis-tls-ca-base64"
  key_vault_id = azurerm_key_vault.main.id
  value        = " "

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

# ---
# DockerHub remote-repository credentials (placeholders; consumed by acr.tf)
# ---
resource "azurerm_key_vault_secret" "dockerhub_username" {
  name         = "${var.prefix}dockerhub-remote-repo-username"
  key_vault_id = azurerm_key_vault.main.id
  value        = " "

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "dockerhub_password" {
  name         = "${var.prefix}dockerhub-remote-repo-password"
  key_vault_id = azurerm_key_vault.main.id
  value        = " "

  depends_on = [azurerm_role_assignment.deployer_kv_secrets_officer]

  lifecycle {
    ignore_changes = [value]
  }
}

