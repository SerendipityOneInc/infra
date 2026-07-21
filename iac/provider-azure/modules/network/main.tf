terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    pkcs12 = {
      source  = "chilicat/pkcs12"
      version = ">= 0.2.5"
    }
  }
}

# ============================================================================
# Virtual network + subnets
#
# Mirrors provider-aws/modules/network (VPC + subnets) and the GCP
# nomad-cluster/network subnetwork. Like GCP (L7 HTTPS LB) and AWS (ALB) we
# stand up an L7 gateway — an Azure Application Gateway v2 — that terminates
# TLS and host-routes: nomad.<domain> straight to the Nomad server pool (4646),
# grpc-api.<domain> to the grpc pool, and everything else (sandbox wildcard,
# api., docker.) to the in-cluster ingress (client-proxy VMSS). Cloudflare
# fronts the gateway (Full SSL mode; self-signed origin cert).
# ============================================================================

# When existing_vnet_name is set, ADD our subnets to that VNet instead of
# creating a new one — used to co-locate the e2b cluster on the shared
# zooclaw-dev-vnet so it reaches the private-endpoint Postgres and JuiceFS meta
# directly (no peering / DNS-link). Otherwise stand up a dedicated VNet.
locals {
  reuse_vnet = var.existing_vnet_name != ""
  vnet_rg    = local.reuse_vnet ? var.existing_vnet_resource_group : var.resource_group_name
  vnet_name  = local.reuse_vnet ? var.existing_vnet_name : azurerm_virtual_network.main[0].name
  vnet_id    = local.reuse_vnet ? data.azurerm_virtual_network.existing[0].id : azurerm_virtual_network.main[0].id
}

data "azurerm_virtual_network" "existing" {
  count               = local.reuse_vnet ? 1 : 0
  name                = var.existing_vnet_name
  resource_group_name = var.existing_vnet_resource_group
}

resource "azurerm_virtual_network" "main" {
  count               = local.reuse_vnet ? 0 : 1
  name                = "${var.prefix}vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space

  tags = var.tags
}

# Cluster nodes (server / api / client / build VMSS). Backend pool members of
# the L4 LB live here.
resource "azurerm_subnet" "cluster" {
  name                 = "${var.prefix}cluster"
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.cluster_subnet_cidr]
}

# Auxiliary services (private endpoints, databases, etc.).
resource "azurerm_subnet" "services" {
  name                 = "${var.prefix}services"
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.services_subnet_cidr]
}

# ============================================================================
# Network Security Group for the cluster subnet.
#
# Translates the AWS ingress security group (alb.tf) and the GCP firewall rules
# (nomad-cluster/network/main.tf) into Azure NSG rules.
# ============================================================================

resource "azurerm_network_security_group" "cluster" {
  name                = "${var.prefix}cluster"
  resource_group_name = var.resource_group_name
  location            = var.location

  # Azure LB health probes originate from the AzureLoadBalancer service tag.
  # Maps to GCP `default-hc` / `client_proxy_firewall_ingress` (health-check
  # source ranges 130.211.0.0/22 & 35.191.0.0/16).
  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = [tostring(var.health_probe_port), tostring(var.ingress_https_port), tostring(var.ingress_http_port)]
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Allow the Application Gateway subnet to reach the cluster backends: the
  # Nomad server pool on the Nomad API port, and the client-proxy ingress on the
  # HTTP/HTTPS ports. The gateway terminates TLS and forwards HTTP to backends.
  security_rule {
    name                       = "AllowAppGatewayToBackends"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = [tostring(var.nomad_api_port), tostring(var.ingress_http_port), tostring(var.ingress_https_port)]
    source_address_prefix      = var.appgw_subnet_cidr
    destination_address_prefix = "*"
  }

  # Public HTTPS to the in-cluster ingress. Maps to AWS ingress SG (443 from
  # 0.0.0.0/0) and the GCP client-proxy path.
  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.ingress_https_port)
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Public HTTP (redirect / ACME). Maps to AWS ingress SG (80 from 0.0.0.0/0).
  security_rule {
    name                       = "AllowHttpInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.ingress_http_port)
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Intra-cluster traffic (Nomad/Consul gossip, orchestrator gRPC, envd, etc.).
  # Maps to the implicit intra-network reachability GCP relies on for the
  # cluster tag. Explicit here even though Azure ships a default
  # AllowVnetInBound rule.
  security_rule {
    name                       = "AllowVnetInbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # SSH for operators. Maps to GCP `internal_remote_connection_firewall_ingress`
  # (22/3389 from the IAP range in prod, open in dev). Source is configurable;
  # defaults to VirtualNetwork (bastion/jumpbox only).
  security_rule {
    name                       = "AllowSshInbound"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_allowed_source
    destination_address_prefix = "*"
  }

  # Explicitly deny SSH/RDP from the public Internet. Maps to GCP
  # `remote_connection_firewall_ingress` (deny 22/3389 from 0.0.0.0/0).
  security_rule {
    name                       = "DenySshRdpFromInternet"
    priority                   = 400
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Allow all egress. Maps to GCP `orch_firewall_egress` (allow all) and the AWS
  # ingress SG egress rule. Explicit even though Azure allows egress by default.
  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = var.tags
}

resource "azurerm_subnet_network_security_group_association" "cluster" {
  subnet_id                 = azurerm_subnet.cluster.id
  network_security_group_id = azurerm_network_security_group.cluster.id
}

# ============================================================================
# NAT gateway for deterministic, static egress. Mirrors the AWS single shared
# NAT gateway and the GCP Cloud NAT (api_use_nat) path.
# ============================================================================

resource "azurerm_public_ip" "nat" {
  name                = "${var.prefix}nat-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = var.tags
}

resource "azurerm_nat_gateway" "main" {
  name                = "${var.prefix}nat"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Standard"

  tags = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "cluster" {
  subnet_id      = azurerm_subnet.cluster.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

resource "azurerm_subnet_nat_gateway_association" "services" {
  subnet_id      = azurerm_subnet.services.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# ============================================================================
# Application Gateway v2 (L7). Replaces the Standard L4 LB and mirrors the AWS
# ALB / GCP L7 HTTPS LB: it terminates TLS and host-routes traffic to three
# backend pools — the Nomad server pool (nomad.<domain> -> 4646), the grpc pool
# (grpc-api.<domain>), and the client-proxy ingress pool (everything else:
# sandbox wildcard, api., docker.). Cloudflare fronts it (Full SSL mode).
# ============================================================================

# App Gateway v2 requires its own dedicated subnet. Do NOT associate the cluster
# NSG or the NAT gateway here — App Gateway manages its own outbound path and
# needs the infrastructure ports opened by its dedicated NSG below.
resource "azurerm_subnet" "appgw" {
  name                 = "${trimsuffix(var.prefix, "-")}-appgw"
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.appgw_subnet_cidr]
}

resource "azurerm_network_security_group" "appgw" {
  name                = "${var.prefix}appgw"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  # App Gateway v2 mandatory infrastructure ports.
  security_rule {
    name                       = "AllowGatewayManager"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
  # Public HTTPS/HTTP to the gateway listeners (Cloudflare fronts this; kept open
  # so Cloudflare's proxy IPs can reach it).
  security_rule {
    name                       = "AllowWebInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "80"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

# ---
# Origin certificate for the App Gateway HTTPS listeners. The zone runs Cloudflare
# "Full (strict)", which validates the origin cert against the Cloudflare Origin
# CA, so we present a Cloudflare Origin CA certificate (SANs cover
# sandbox2.<domain> + *.sandbox2.<domain>). The cert + key live in Key Vault
# (secrets appgw-origin-cert / appgw-origin-key, populated out-of-band); terraform
# reads them and packs a PFX for the gateway ssl_certificate. Rotate by replacing
# the KV secrets and re-applying.
# ---
resource "random_password" "appgw_cert" {
  length  = 24
  special = false
}

data "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

data "azurerm_key_vault_secret" "appgw_origin_cert" {
  name         = "appgw-origin-cert"
  key_vault_id = data.azurerm_key_vault.main.id
}

data "azurerm_key_vault_secret" "appgw_origin_key" {
  name         = "appgw-origin-key"
  key_vault_id = data.azurerm_key_vault.main.id
}

resource "pkcs12_from_pem" "appgw" {
  password        = random_password.appgw_cert.result
  cert_pem        = data.azurerm_key_vault_secret.appgw_origin_cert.value
  private_key_pem = data.azurerm_key_vault_secret.appgw_origin_key.value
}

resource "azurerm_public_ip" "appgw" {
  name                = "${var.prefix}appgw-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

locals {
  appgw_name          = "${var.prefix}appgw"
  appgw_fe_ip         = "appgw-frontend-ip"
  appgw_fe_port_https = "https"
  appgw_fe_port_http  = "http"
  appgw_ssl_cert      = "appgw-cert"
  appgw_ip_config     = "appgw-ipcfg"
  # backend pools
  pool_nomad   = "nomad-pool"
  pool_ingress = "ingress-pool"
  pool_grpc    = "grpc-pool"
  # http settings
  set_nomad   = "nomad-http"
  set_ingress = "ingress-http"
  set_grpc    = "grpc-http"
  # probes
  probe_nomad   = "nomad-probe"
  probe_ingress = "ingress-probe"
  probe_grpc    = "grpc-probe"
  # listeners
  lst_nomad   = "nomad-listener"
  lst_grpc    = "grpc-listener"
  lst_default = "default-listener"
  lst_http    = "http-listener"
}

resource "azurerm_application_gateway" "main" {
  name                = local.appgw_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 2
  }

  gateway_ip_configuration {
    name      = local.appgw_ip_config
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_ip_configuration {
    name                 = local.appgw_fe_ip
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = local.appgw_fe_port_https
    port = 443
  }
  frontend_port {
    name = local.appgw_fe_port_http
    port = 80
  }

  ssl_certificate {
    name     = local.appgw_ssl_cert
    data     = pkcs12_from_pem.appgw.result
    password = random_password.appgw_cert.result
  }

  # ---- backend pools (empty; VMSS instances register via their ipconfig) ----
  backend_address_pool { name = local.pool_nomad }
  backend_address_pool { name = local.pool_ingress }
  backend_address_pool { name = local.pool_grpc }

  # ---- probes ----
  probe {
    name                                      = local.probe_nomad
    protocol                                  = "Http"
    path                                      = "/v1/agent/health"
    port                                      = var.nomad_api_port
    interval                                  = 5
    timeout                                   = 5
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = false
    host                                      = "127.0.0.1"
    match { status_code = ["200-399"] }
  }
  probe {
    name                                      = local.probe_ingress
    protocol                                  = "Http"
    path                                      = var.health_probe_path
    port                                      = var.ingress_http_port
    interval                                  = 5
    timeout                                   = 5
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = false
    host                                      = "127.0.0.1"
    match { status_code = ["200-399"] }
  }
  probe {
    name                                      = local.probe_grpc
    protocol                                  = "Http"
    path                                      = var.health_probe_path
    port                                      = var.ingress_http_port
    interval                                  = 5
    timeout                                   = 5
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = false
    host                                      = "127.0.0.1"
    match { status_code = ["200-399"] }
  }

  # ---- backend http settings (gateway terminates TLS, talks HTTP to backends) ----
  backend_http_settings {
    name                  = local.set_nomad
    cookie_based_affinity = "Disabled"
    protocol              = "Http"
    port                  = var.nomad_api_port
    request_timeout       = 60
    probe_name            = local.probe_nomad
  }
  backend_http_settings {
    name                  = local.set_ingress
    cookie_based_affinity = "Disabled"
    protocol              = "Http"
    port                  = var.ingress_http_port
    request_timeout       = 86400
    probe_name            = local.probe_ingress
  }
  backend_http_settings {
    name                  = local.set_grpc
    cookie_based_affinity = "Disabled"
    protocol              = "Http"
    port                  = var.ingress_http_port
    request_timeout       = 86400
    probe_name            = local.probe_grpc
  }

  # ---- listeners (multi-site host-based on 443; one default catch-all) ----
  http_listener {
    name                           = local.lst_nomad
    frontend_ip_configuration_name = local.appgw_fe_ip
    frontend_port_name             = local.appgw_fe_port_https
    protocol                       = "Https"
    ssl_certificate_name           = local.appgw_ssl_cert
    host_name                      = "nomad.${var.domain_name}"
  }
  http_listener {
    name                           = local.lst_grpc
    frontend_ip_configuration_name = local.appgw_fe_ip
    frontend_port_name             = local.appgw_fe_port_https
    protocol                       = "Https"
    ssl_certificate_name           = local.appgw_ssl_cert
    host_name                      = "grpc-api.${var.domain_name}"
  }
  http_listener {
    name                           = local.lst_default
    frontend_ip_configuration_name = local.appgw_fe_ip
    frontend_port_name             = local.appgw_fe_port_https
    protocol                       = "Https"
    ssl_certificate_name           = local.appgw_ssl_cert
    # no host_name => default/catch-all (sandbox wildcard, api, docker)
  }
  http_listener {
    name                           = local.lst_http
    frontend_ip_configuration_name = local.appgw_fe_ip
    frontend_port_name             = local.appgw_fe_port_http
    protocol                       = "Http"
  }

  # ---- routing rules (v2 requires unique integer priority per rule) ----
  request_routing_rule {
    name                       = "nomad-rule"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = local.lst_nomad
    backend_address_pool_name  = local.pool_nomad
    backend_http_settings_name = local.set_nomad
  }
  request_routing_rule {
    name                       = "grpc-rule"
    rule_type                  = "Basic"
    priority                   = 110
    http_listener_name         = local.lst_grpc
    backend_address_pool_name  = local.pool_grpc
    backend_http_settings_name = local.set_grpc
  }
  request_routing_rule {
    name                       = "default-rule"
    rule_type                  = "Basic"
    priority                   = 120
    http_listener_name         = local.lst_default
    backend_address_pool_name  = local.pool_ingress
    backend_http_settings_name = local.set_ingress
  }
  # HTTP -> HTTPS redirect
  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = local.lst_default
    include_path         = true
    include_query_string = true
  }
  request_routing_rule {
    name                        = "http-redirect-rule"
    rule_type                   = "Basic"
    priority                    = 130
    http_listener_name          = local.lst_http
    redirect_configuration_name = "http-to-https"
  }

  lifecycle {
    # VMSS instances register into the backend pools out-of-band; don't fight it.
    ignore_changes = [backend_address_pool]
  }
}
