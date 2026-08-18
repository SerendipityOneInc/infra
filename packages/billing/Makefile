ENV := $(shell cat ../../.last_used_env || echo "not-set")
-include ../../.env.${ENV}
PREFIX := $(strip $(subst ",,$(PREFIX)))

IMAGE_REGISTRY := $(ACR_NAME).azurecr.io/$(PREFIX)core/billing

.PHONY: build
build:
	CGO_ENABLED=0 go build -o bin/billing .

.PHONY: test
test:
	go test -race ./...

.PHONY: build-and-upload
build-and-upload:
ifeq ($(PROVIDER),azure)
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	docker build --platform linux/amd64 --tag $(IMAGE_REGISTRY) --tag $(IMAGE_REGISTRY):$(COMMIT_SHA) --push -f ./Dockerfile ..
else
	@echo "billing is currently supported only on Azure" >&2
	@exit 2
endif
