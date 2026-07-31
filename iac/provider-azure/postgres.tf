# e2b is the upper-infra layer: it reuses the base-infra Postgres Flexible Server
# (managed by azure-foundation) but owns the `e2b` DATABASE it needs, created via
# the ARM control plane (no data-plane/VNet connectivity required). The app
# connects with the server admin credentials against this database
# (POSTGRES_CONNECTION_STRING in .env.<provider>-<environment>); the database is isolated per-app.
# A dedicated Postgres role is intentionally not created here — that is a
# data-plane operation against the private server and stays out of this stack.

data "azurerm_postgresql_flexible_server" "existing" {
  count               = var.existing_pg_server_name != "" ? 1 : 0
  name                = var.existing_pg_server_name
  resource_group_name = var.existing_pg_resource_group
}

resource "azurerm_postgresql_flexible_server_database" "e2b" {
  count     = var.existing_pg_server_name != "" ? 1 : 0
  name      = var.e2b_database_name
  server_id = data.azurerm_postgresql_flexible_server.existing[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"

  # Never drop the database on `terraform destroy` — it may hold sandbox/template
  # state. Tear it down deliberately if ever needed.
  lifecycle {
    prevent_destroy = true
  }
}
