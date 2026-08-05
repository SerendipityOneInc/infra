ENV := $(shell cat ../../../.last_used_env || echo "not-set")
-include ../../../.env.${ENV}

# Azure Compute Gallery (Shared Image Gallery) destination for the built image
# version. The gallery + image definition must exist before `make build` runs
# (create them once with `make gallery`). Override any of these via the env.
PACKER_GALLERY_RESOURCE_GROUP ?= $(AZURE_RESOURCE_GROUP)
PACKER_GALLERY_NAME           ?= $(shell echo "$(PREFIX)orch_gallery" | tr -cd 'a-zA-Z0-9_.')
PACKER_IMAGE_NAME             ?= $(PREFIX)orch
PACKER_IMAGE_VERSION          ?= $(shell date +%Y.%m.%d)

# Resource id of the published gallery image version. Feed this into terraform as
# TF_VAR_cluster_image_id (see `make image-id`).
GALLERY_IMAGE_ID = /subscriptions/$(AZURE_SUBSCRIPTION_ID)/resourceGroups/$(PACKER_GALLERY_RESOURCE_GROUP)/providers/Microsoft.Compute/galleries/$(PACKER_GALLERY_NAME)/images/$(PACKER_IMAGE_NAME)/versions/$(PACKER_IMAGE_VERSION)

.PHONY: init
init:
	packer init -upgrade .

# Create the Compute Gallery and a Gen2 Linux image definition (idempotent).
# Run once per environment before the first `make build`.
#
# The definition declares DiskControllerTypes because the v6 machine families
# boot only from NVMe and refuse a SCSI-only image. That capability cannot be
# added to an existing definition, so getting it wrong here means creating a
# second definition and rebuilding — which is exactly what dev and staging had
# to do (hence their e2b-orch alongside e2b-orch-nvme).
#
# The value must be one quoted KEY=VALUE with no space after the comma: --features
# takes space-separated pairs, so "SCSI, NVMe" splits and the CLI rejects it.
# Azure stores it back as "SCSI, NVMe" regardless.
.PHONY: gallery
gallery:
	az sig create \
		--subscription $(AZURE_SUBSCRIPTION_ID) \
		--resource-group $(PACKER_GALLERY_RESOURCE_GROUP) \
		--gallery-name $(PACKER_GALLERY_NAME) \
		--location $(AZURE_LOCATION) --output none 2>/dev/null || true
	az sig image-definition create \
		--subscription $(AZURE_SUBSCRIPTION_ID) \
		--resource-group $(PACKER_GALLERY_RESOURCE_GROUP) \
		--gallery-name $(PACKER_GALLERY_NAME) \
		--gallery-image-definition $(PACKER_IMAGE_NAME) \
		--publisher e2b --offer orch --sku 22_04-lts-gen2 \
		--os-type Linux --os-state Generalized \
		--hyper-v-generation V2 \
		--features "DiskControllerTypes=SCSI,NVMe" \
		--location $(AZURE_LOCATION) --output none 2>/dev/null || true

.PHONY: build
build:
	packer build \
		$(if $(PACKER_CONSUL_VERSION),-var "consul_version=$(PACKER_CONSUL_VERSION)") \
		$(if $(PACKER_NOMAD_VERSION),-var "nomad_version=$(PACKER_NOMAD_VERSION)") \
		$(if $(PACKER_IMAGE_SKU),-var "image_sku=$(PACKER_IMAGE_SKU)") \
		$(if $(PACKER_BASE_VM_SIZE),-var "base_vm_size=$(PACKER_BASE_VM_SIZE)") \
		-var "prefix=$(PREFIX)" \
		-var "subscription_id=$(AZURE_SUBSCRIPTION_ID)" \
		-var "tenant_id=$(AZURE_TENANT_ID)" \
		-var "location=$(AZURE_LOCATION)" \
		-var "gallery_resource_group=$(PACKER_GALLERY_RESOURCE_GROUP)" \
		-var "gallery_name=$(PACKER_GALLERY_NAME)" \
		-var "image_name=$(PACKER_IMAGE_NAME)" \
		-var "image_version=$(PACKER_IMAGE_VERSION)" \
		.
	@ printf "\nBuilt gallery image version. Feed this id into terraform:\n"
	@ printf "  TF_VAR_cluster_image_id=%s\n" "$(GALLERY_IMAGE_ID)"

# Print the resource id of the gallery image version for the current
# PACKER_IMAGE_VERSION (wire into the nodepool cluster_image_id variable).
.PHONY: image-id
image-id:
	@ echo "$(GALLERY_IMAGE_ID)"

.PHONY: validate
validate:
	packer validate \
		-var "subscription_id=$(AZURE_SUBSCRIPTION_ID)" \
		-var "tenant_id=$(AZURE_TENANT_ID)" \
		-var "location=$(AZURE_LOCATION)" \
		-var "gallery_resource_group=$(PACKER_GALLERY_RESOURCE_GROUP)" \
		-var "gallery_name=$(PACKER_GALLERY_NAME)" \
		-var "image_name=$(PACKER_IMAGE_NAME)" \
		-var "image_version=$(PACKER_IMAGE_VERSION)" \
		.

.PHONY: format
format:
	packer fmt .
