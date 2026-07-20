# ---
# Virtual network
# ---
output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
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
# L4 load balancer
# ---
output "lb_id" {
  value = azurerm_lb.ingress.id
}

output "lb_public_ip_id" {
  value = azurerm_public_ip.lb.id
}

output "lb_frontend_ip" {
  description = "Public frontend IP of the L4 ingress load balancer. Cloudflare records point here."
  value       = azurerm_public_ip.lb.ip_address
}

output "lb_backend_pool_id" {
  description = "Backend address pool id. The client-proxy VMSS attaches its instances to this pool."
  value       = azurerm_lb_backend_address_pool.ingress.id
}

output "lb_frontend_ip_configuration_name" {
  value = azurerm_lb.ingress.frontend_ip_configuration[0].name
}
