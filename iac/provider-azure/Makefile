ENV := $(shell cat ../../.last_used_env || echo "not-set")
ENV_FILE := ../../.env.${ENV}

-include ${ENV_FILE}

TF := $(shell which terraform)
TF_VAR_FILE := ./.terraform.${ENV}.tfvars
TF_VAR_FILE_ARG := $(if $(wildcard $(TF_VAR_FILE)),-var-file=$(TF_VAR_FILE))

# Backend state lives in a dedicated resource group + storage account, created
# by `make init` before terraform runs (it cannot live in the account terraform
# itself manages). Override any of these via the environment if needed.
TERRAFORM_STATE_RESOURCE_GROUP  ?= $(AZURE_RESOURCE_GROUP)-tfstate
TERRAFORM_STATE_STORAGE_ACCOUNT ?= $(shell echo "$(PREFIX)$(TERRAFORM_ENVIRONMENT)tfstate" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-24)
TERRAFORM_STATE_CONTAINER       ?= tfstate
TERRAFORM_STATE_KEY             ?= terraform/orchestration/state

backend_config := \
	-backend-config="resource_group_name=$(TERRAFORM_STATE_RESOURCE_GROUP)" \
	-backend-config="storage_account_name=$(TERRAFORM_STATE_STORAGE_ACCOUNT)" \
	-backend-config="container_name=$(TERRAFORM_STATE_CONTAINER)" \
	-backend-config="key=$(TERRAFORM_STATE_KEY)" \
	-backend-config="subscription_id=$(AZURE_SUBSCRIPTION_ID)" \
	-backend-config="tenant_id=$(AZURE_TENANT_ID)"

SKIP_FMT ?= false
define tf_fmt
$(if $(filter true,$(SKIP_FMT)),,$(TF) fmt -recursive)
endef

# Set the terraform environment variable only if the environment variable is set
# Strip the passed variable name (it's space sensitive) and check if the variable is set, if yes return TF_VAR_<variable_name>=<value> with the variable name in lower case
define tfvar
$(if $(value $(strip $(1))), TF_VAR_$(shell echo $(strip $(1)) | tr A-Z a-z)=$($(strip $(1))))
endef

# Azure-specific vars whose TF variable name differs from the env var name are
# threaded explicitly; the rest go through the generic $(tfvar) helper.
tf_vars := \
	ARM_SUBSCRIPTION_ID=$(AZURE_SUBSCRIPTION_ID) \
	ARM_TENANT_ID=$(AZURE_TENANT_ID) \
	TF_VAR_environment=$(TERRAFORM_ENVIRONMENT) \
	TF_VAR_subscription_id=$(AZURE_SUBSCRIPTION_ID) \
	TF_VAR_tenant_id=$(AZURE_TENANT_ID) \
	TF_VAR_location=$(AZURE_LOCATION) \
	TF_VAR_resource_group_name=$(AZURE_RESOURCE_GROUP) \
	TF_VAR_storage_account_name=$(AZURE_STORAGE_ACCOUNT) \
	TF_VAR_acr_name=$(ACR_NAME) \
	$(call tfvar, PREFIX) \
	$(call tfvar, DOMAIN_NAME) \
	$(call tfvar, KEY_VAULT_NAME) \
	$(call tfvar, POSTGRES_CONNECTION_STRING) \
	$(call tfvar, REMOTE_REPOSITORY_ENABLED) \
	$(call tfvar, ALLOW_SANDBOX_INTERNAL_CIDRS) \
	$(call tfvar, API_INTERNAL_GRPC_PORT) \
	$(call tfvar, CONTROL_SERVER_CLUSTER_SIZE) \
	$(call tfvar, CONTROL_SERVER_MACHINE_TYPE) \
	$(call tfvar, API_CLUSTER_SIZE) \
	$(call tfvar, API_SERVER_MACHINE_TYPE) \
	$(call tfvar, BUILD_CLUSTER_SIZE) \
	$(call tfvar, BUILD_SERVER_MACHINE_TYPE) \
	$(call tfvar, BUILD_SERVER_NESTED_VIRTUALIZATION) \
	$(call tfvar, CLIENT_CLUSTER_SIZE) \
	$(call tfvar, CLIENT_SERVER_MACHINE_TYPE) \
	$(call tfvar, CLIENT_SERVER_NESTED_VIRTUALIZATION) \
	$(call tfvar, CLICKHOUSE_CLUSTER_SIZE) \
	$(call tfvar, CLICKHOUSE_SERVER_MACHINE_TYPE) \
	$(call tfvar, INGRESS_COUNT) \
	$(call tfvar, CLIENT_PROXY_COUNT) \
	$(call tfvar, DB_MAX_OPEN_CONNECTIONS) \
	$(call tfvar, DB_MIN_IDLE_CONNECTIONS) \
	$(call tfvar, AUTH_DB_MAX_OPEN_CONNECTIONS) \
	$(call tfvar, AUTH_DB_MIN_IDLE_CONNECTIONS)

.PHONY: provider-login
provider-login:
	az acr login --name $(ACR_NAME)

.PHONY: switch
switch:
	@ printf "Switching Terraform backend for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(tf_vars) $(TF) init -input=false -upgrade -reconfigure $(backend_config)

.PHONY: init
init:
	@ printf "Initializing Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	# Create the state resource group, storage account and container if absent (idempotent)
	az group create --name $(TERRAFORM_STATE_RESOURCE_GROUP) --location $(AZURE_LOCATION) --subscription $(AZURE_SUBSCRIPTION_ID) --output none
	az storage account create --name $(TERRAFORM_STATE_STORAGE_ACCOUNT) --resource-group $(TERRAFORM_STATE_RESOURCE_GROUP) --location $(AZURE_LOCATION) --sku Standard_LRS --kind StorageV2 --subscription $(AZURE_SUBSCRIPTION_ID) --min-tls-version TLS1_2 --allow-blob-public-access false --output none 2>/dev/null || true
	az storage container create --name $(TERRAFORM_STATE_CONTAINER) --account-name $(TERRAFORM_STATE_STORAGE_ACCOUNT) --auth-mode login --subscription $(AZURE_SUBSCRIPTION_ID) --output none 2>/dev/null || true
	$(tf_vars) $(TF) init -input=false -upgrade -reconfigure $(backend_config)
	$(tf_vars) $(TF) apply -target=module.init -input=false -compact-warnings

.PHONY: plan
plan:
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(call tf_fmt)
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -input=false -compact-warnings -parallelism=20

.PHONY: plan-without-jobs
plan-without-jobs:
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(eval TARGET := $(shell cat main.tf | grep "^module" | awk '{print $$2}' | tr ' ' '\n' | grep -v -e "nomad" | awk '{print "-target=module." $$0 ""}' | xargs))
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -input=false -compact-warnings -parallelism=20 $(TARGET)

.PHONY: apply
apply:
	@ printf "Applying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) apply -auto-approve -input=false -compact-warnings -parallelism=20 .tfplan.$(ENV)

.PHONY: apply-init
apply-init:
	@ $(tf_vars) $(TF) apply $(TF_VAR_FILE_ARG) -target=module.init -auto-approve -input=false -compact-warnings

.PHONY: move
move:
	@ printf "Moving resource for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) state mv "$(SOURCE)" "$(TARGET)" -no-color

.PHONY: destroy
destroy:
	@ printf "Destroying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) destroy $(TF_VAR_FILE_ARG)

