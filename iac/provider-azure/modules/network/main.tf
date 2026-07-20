terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
  }
}

# ============================================================================
# Virtual network + subnets
#
# Mirrors provider-aws/modules/network (VPC + subnets) and the GCP
# nomad-cluster/network subnetwork. Unlike GCP/AWS we do NOT stand up an L7
# load balancer: a single Standard (L4) azurerm_lb forwards raw TCP 443/80 to
# the in-cluster ingress (client-proxy VMSS), which terminates TLS and performs
# all host/path routing. Cloudflare provides edge WAF/DDoS/TLS.
# ============================================================================

resource "azurerm_virtual_network" "main" {
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
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.cluster_subnet_cidr]
}

# Auxiliary services (private endpoints, databases, etc.).
resource "azurerm_subnet" "services" {
  name                 = "${var.prefix}services"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
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
# Standard (L4) load balancer. Replaces the AWS L7 ALB and the GCP L7 URL-map
# stack. Forwards raw TCP 443/80 to the in-cluster ingress backend pool; the
# ingress terminates TLS and does all host/path routing.
# ============================================================================

resource "azurerm_public_ip" "lb" {
  name                = "${var.prefix}lb-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = var.tags
}

resource "azurerm_lb" "ingress" {
  name                = "${var.prefix}ingress"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "${var.prefix}ingress-frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }

  tags = var.tags
}

# Backend pool for the ingress / client-proxy nodes. Deliberately created empty:
# the client-proxy VMSS does not exist yet (later chunk). The VMSS network
# profile will reference this pool's id (exported via outputs) so its instances
# register automatically. No membership is wired here.
resource "azurerm_lb_backend_address_pool" "ingress" {
  name            = "${var.prefix}ingress-backend"
  loadbalancer_id = azurerm_lb.ingress.id
}

resource "azurerm_lb_probe" "ingress" {
  name                = "${var.prefix}ingress-health"
  loadbalancer_id     = azurerm_lb.ingress.id
  protocol            = var.health_probe_protocol
  port                = var.health_probe_port
  request_path        = var.health_probe_protocol == "Tcp" ? null : var.health_probe_path
  interval_in_seconds = var.health_probe_interval_seconds
  number_of_probes    = var.health_probe_number_of_probes
}

# 443 -> ingress TLS port. Raw TCP pass-through (TLS terminated in-cluster).
resource "azurerm_lb_rule" "https" {
  name                           = "${var.prefix}https"
  loadbalancer_id                = azurerm_lb.ingress.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = var.ingress_https_port
  frontend_ip_configuration_name = azurerm_lb.ingress.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.ingress.id]
  probe_id                       = azurerm_lb_probe.ingress.id
  tcp_reset_enabled              = true
  # Egress is handled by the NAT gateway, so the LB must not also SNAT.
  disable_outbound_snat = true
}

# 80 -> ingress HTTP port (redirect / ACME).
resource "azurerm_lb_rule" "http" {
  name                           = "${var.prefix}http"
  loadbalancer_id                = azurerm_lb.ingress.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = var.ingress_http_port
  frontend_ip_configuration_name = azurerm_lb.ingress.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.ingress.id]
  probe_id                       = azurerm_lb_probe.ingress.id
  tcp_reset_enabled              = true
  disable_outbound_snat          = true
}
