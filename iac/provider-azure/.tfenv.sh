#!/bin/bash
# Mirror the Makefile tf_vars so terraform can be driven directly (import/plan/apply).
#
# Follow .last_used_env the way every Makefile here does. This used to source a
# fixed env file, which meant sourcing one environment's credentials while
# .last_used_env — and therefore the Makefile, the var-file and the backend —
# pointed at another. Env files are named .env.<provider>-<environment>.
# No set -e/-u here: this file is sourced, so they would leak into the caller's
# shell, and the optional-passthrough loop below probes unset variables on purpose.
ENV=$(cat ../../.last_used_env 2>/dev/null || true)
if [ -z "$ENV" ]; then
  echo "no ../../.last_used_env; run 'make switch-env ENV=<provider>-<environment>' first" >&2
  return 1 2>/dev/null || exit 1
fi
ENV_FILE="../../.env.$ENV"
if [ ! -f "$ENV_FILE" ]; then
  echo "$ENV_FILE not found (ENV=$ENV)" >&2
  return 1 2>/dev/null || exit 1
fi
echo "tfenv: sourcing $ENV_FILE" >&2
set -a
source "$ENV_FILE"
set +a
export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
export ARM_TENANT_ID="$AZURE_TENANT_ID"
export TF_VAR_environment="$TERRAFORM_ENVIRONMENT"
export TF_VAR_subscription_id="$AZURE_SUBSCRIPTION_ID"
export TF_VAR_tenant_id="$AZURE_TENANT_ID"
export TF_VAR_location="$AZURE_LOCATION"
export TF_VAR_resource_group_name="$AZURE_RESOURCE_GROUP"
export TF_VAR_storage_account_name="$AZURE_STORAGE_ACCOUNT"
export TF_VAR_acr_name="$ACR_NAME"
# Optional passthroughs — export only when present (matches $(call tfvar,...))
for v in PREFIX DOMAIN_NAME KEY_VAULT_NAME POSTGRES_CONNECTION_STRING \
         REMOTE_REPOSITORY_ENABLED ALLOW_SANDBOX_INTERNAL_CIDRS API_INTERNAL_GRPC_PORT \
         CONTROL_SERVER_CLUSTER_SIZE CONTROL_SERVER_MACHINE_TYPE API_CLUSTER_SIZE API_SERVER_MACHINE_TYPE \
         BUILD_CLUSTER_SIZE BUILD_SERVER_MACHINE_TYPE BUILD_SERVER_NESTED_VIRTUALIZATION \
         CLIENT_CLUSTER_SIZE CLIENT_SERVER_MACHINE_TYPE CLIENT_SERVER_NESTED_VIRTUALIZATION \
         CLICKHOUSE_CLUSTER_SIZE CLICKHOUSE_SERVER_MACHINE_TYPE INGRESS_COUNT CLIENT_PROXY_COUNT \
         DB_MAX_OPEN_CONNECTIONS DB_MIN_IDLE_CONNECTIONS AUTH_DB_MAX_OPEN_CONNECTIONS AUTH_DB_MIN_IDLE_CONNECTIONS; do
  eval "val=\$$v"
  [ -n "$val" ] && export "TF_VAR_$(echo "$v" | tr 'A-Z' 'a-z')=$val"
done
