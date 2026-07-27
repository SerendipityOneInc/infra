# ---
# Managed Identity
# ---
output "identity_id" {
  value = azurerm_user_assigned_identity.infra_instances.id
}

output "identity_client_id" {
  value = azurerm_user_assigned_identity.infra_instances.client_id
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.infra_instances.principal_id
}

# ---
# Storage account + containers
# ---
output "storage_account_name" {
  value = azurerm_storage_account.storage.name
}

output "storage_account_id" {
  value = azurerm_storage_account.storage.id
}

output "setup_container_name" {
  value = azurerm_storage_container.containers["setup"].name
}

output "fc_kernels_container_name" {
  value = azurerm_storage_container.containers["fc_kernels"].name
}

output "fc_versions_container_name" {
  value = azurerm_storage_container.containers["fc_versions"].name
}

output "fc_env_pipeline_container_name" {
  value = azurerm_storage_container.containers["fc_env_pipeline"].name
}

output "fc_busybox_container_name" {
  value = azurerm_storage_container.containers["fc_busybox"].name
}

output "fc_template_container_name" {
  value = azurerm_storage_container.containers["fc_templates"].name
}

output "fc_build_cache_container_name" {
  value = azurerm_storage_container.containers["fc_build_cache"].name
}

output "loki_container_name" {
  value = azurerm_storage_container.containers["loki"].name
}

output "clickhouse_backups_container_name" {
  value = azurerm_storage_container.containers["clickhouse_backups"].name
}

# ---
# Container registry
# ---
output "acr_login_server" {
  value = azurerm_container_registry.core.login_server
}

output "acr_id" {
  value = azurerm_container_registry.core.id
}

# Image path prefixes inside the single ACR (mirror the ECR/Artifact Registry
# repository-name outputs; ACR creates repositories lazily on push).
output "core_repository_name" {
  value = "${var.prefix}core"
}

output "custom_environments_repository_name" {
  value = "${var.prefix}core/custom-environments"
}

output "api_repository_name" {
  value = "${var.prefix}core/api"
}

output "db_migrator_repository_name" {
  value = "${var.prefix}core/db-migrator"
}

output "client_proxy_repository_name" {
  value = "${var.prefix}core/client-proxy"
}

output "clickhouse_migrator_repository_name" {
  value = "${var.prefix}core/clickhouse-migrator"
}

# ---
# Key Vault
# ---
output "key_vault_id" {
  value = azurerm_key_vault.main.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

# ---
# Secrets
# ---
output "cluster" {
  sensitive = true
  value = {
    nomad_acl_token              = random_uuid.nomad_acl_token.result
    consul_acl_token             = random_uuid.consul_acl_token.result
    consul_dns_request_token     = random_uuid.consul_dns_request_token.result
    consul_gossip_encryption_key = random_id.consul_gossip_encryption_key.b64_std
  }
}

output "clickhouse" {
  sensitive = true
  value = {
    username      = "e2b"
    password      = random_password.clickhouse_password.result
    server_secret = random_password.clickhouse_server_secret.result
  }
}

output "api_secret" {
  value     = random_password.api_secret.result
  sensitive = true
}

output "admin_token" {
  value     = random_password.admin_token.result
  sensitive = true
}

output "sandbox_access_token_hash_seed" {
  value     = random_password.sandbox_access_token_hash_seed.result
  sensitive = true
}

output "postgres_connection_string" {
  value     = data.azurerm_key_vault_secret.postgres_connection_string.value
  sensitive = true
}

output "postgres_connection_string_secret_name" {
  value = azurerm_key_vault_secret.postgres_connection_string.name
}

output "launch_darkly_api_key" {
  value     = data.azurerm_key_vault_secret.launch_darkly_api_key.value
  sensitive = true
}

output "redis_cluster_url_secret_name" {
  value = azurerm_key_vault_secret.redis_cluster_url.name
}

output "redis_tls_ca_base64_secret_name" {
  value = azurerm_key_vault_secret.redis_tls_ca_base64.name
}

# ---
# Cloudflare
# ---
output "cloudflare" {
  sensitive = true
  value = {
    token = data.azurerm_key_vault_secret.cloudflare_api_token.value
  }
}


output "storage_account_primary_key" {
  value     = azurerm_storage_account.storage.primary_access_key
  sensitive = true
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}
