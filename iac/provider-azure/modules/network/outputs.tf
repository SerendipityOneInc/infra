# ---
# Virtual network
# ---
output "vnet_id" {
  value = local.vnet_id
}

output "vnet_name" {
  value = local.vnet_name
}

# ---
# Subnets
# ---
output "cluster_subnet_id" {
  value = azurerm_subnet.cluster.id
}

output "services_subnet_id" {
  value = azurerm_subnet.services.id
}

output "subnet_ids" {
  description = "Map of logical subnet name -> subnet id"
  value = {
    cluster  = azurerm_subnet.cluster.id
    services = azurerm_subnet.services.id
  }
}

# ---
# Network security groups
# ---
output "cluster_nsg_id" {
  value = azurerm_network_security_group.cluster.id
}

output "nsg_ids" {
  description = "Map of logical NSG name -> NSG id"
  value = {
    cluster = azurerm_network_security_group.cluster.id
  }
}

# ---
# NAT gateway (egress)
# ---
output "nat_gateway_id" {
  value = azurerm_nat_gateway.main.id
}

output "nat_public_ip" {
  description = "Static egress IP shared by the cluster subnets"
  value       = azurerm_public_ip.nat.ip_address
}

# ---
# Application Gateway v2 (L7)
# ---
output "appgw_public_ip" {
  description = "Public frontend IP of the Application Gateway. Cloudflare records point here."
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_id" {
  value = azurerm_application_gateway.main.id
}

output "ingress_backend_pool_id" {
  description = "App Gateway backend pool for the client-proxy ingress (sandbox wildcard / api / docker)."
  value       = one([for p in azurerm_application_gateway.main.backend_address_pool : p.id if p.name == "ingress-pool"])
}

output "grpc_backend_pool_id" {
  description = "App Gateway backend pool for the grpc-api pool."
  value       = one([for p in azurerm_application_gateway.main.backend_address_pool : p.id if p.name == "grpc-pool"])
}

output "nomad_backend_pool_id" {
  description = "App Gateway backend pool for the Nomad server pool (control-server:4646)."
  value       = one([for p in azurerm_application_gateway.main.backend_address_pool : p.id if p.name == "nomad-pool"])
}

output "appgw_private_ip" {
  description = "App Gateway private frontend IP (internal domain resolves here via the Private DNS zone)."
  value       = local.appgw_private_fe_ip
}

output "internal_domain_name" {
  description = "Internal-only domain served by the private frontend (set E2B_DOMAIN to this for in-VNet consumers)."
  value       = var.internal_domain_name
}

output "dataplane_public_ip" {
  description = "Public IP of the sandbox data-plane L4 LB (external *.<domain> wildcard points here)."
  value       = azurerm_public_ip.dataplane.ip_address
}

output "dataplane_private_ip" {
  description = "Private frontend IP of the data-plane L4 LB (internal *.<internal_domain> wildcard points here via Private DNS)."
  value       = local.dataplane_private_fe_ip
}

output "dataplane_backend_pool_ids" {
  description = "Backend pools (public + internal LB) the api/ingress VMSS joins so both L4 LBs reach Traefik on 443."
  value       = [azurerm_lb_backend_address_pool.dataplane_public.id, azurerm_lb_backend_address_pool.dataplane_internal.id]
}
