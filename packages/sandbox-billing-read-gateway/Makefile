ENV := $(shell cat ../../.last_used_env || echo "not-set")
-include ../../.env.${ENV}
PREFIX := $(strip $(subst ",,$(PREFIX)))

ifeq ($(PROVIDER),azure)
	IMAGE_REGISTRY := $(ACR_NAME).azurecr.io/$(PREFIX)core/sandbox-billing-read-gateway
else
	$(error sandbox-billing-read-gateway is currently supported only on Azure)
endif

.PHONY: build
build:
	CGO_ENABLED=0 go build -o bin/sandbox-billing-read-gateway .

.PHONY: test
test:
	go test -race ./...

.PHONY: build-and-upload
build-and-upload:
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	docker build --platform linux/amd64 --tag $(IMAGE_REGISTRY) --tag $(IMAGE_REGISTRY):$(COMMIT_SHA) --push -f ./Dockerfile ..
