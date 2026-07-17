# ---
# Container registry. AWS/GCP create one repository per image (ECR/Artifact
# Registry); Azure Container Registry is a single registry that holds every
# image under a path, so images live at <acr>.azurecr.io/<prefix>core/<name>.
# The `core` repo namespace is therefore just a path prefix, not a resource.
# ---
resource "azurerm_container_registry" "core" {
  name                = var.acr_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.acr_sku
  admin_enabled       = false

  tags = var.tags
}

# ---
# DockerHub pull-through cache (mirrors provider-gcp/remote-repository). Gated so
# it is only created when remote_repository_enabled is true. Credentials come
# from Key Vault so DockerHub rate limits can be lifted with an authenticated
# account.
# ---
resource "azurerm_container_registry_credential_set" "dockerhub" {
  count = var.remote_repository_enabled ? 1 : 0

  name                  = "dockerhub"
  container_registry_id = azurerm_container_registry.core.id
  login_server          = "docker.io"

  authentication_credentials {
    username_secret_id = azurerm_key_vault_secret.dockerhub_username.versionless_id
    password_secret_id = azurerm_key_vault_secret.dockerhub_password.versionless_id
  }

  identity {
    type = "SystemAssigned"
  }
}

# The credential set's system-assigned identity must be able to read the
# DockerHub secrets from Key Vault.
resource "azurerm_role_assignment" "dockerhub_credential_set_kv" {
  count = var.remote_repository_enabled ? 1 : 0

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_container_registry_credential_set.dockerhub[0].identity[0].principal_id
}

resource "azurerm_container_registry_cache_rule" "dockerhub" {
  count = var.remote_repository_enabled ? 1 : 0

  name                  = "dockerhub"
  container_registry_id = azurerm_container_registry.core.id
  source_repo           = "docker.io/library/*"
  target_repo           = "docker-remote/*"
  credential_set_id     = azurerm_container_registry_credential_set.dockerhub[0].id
}

