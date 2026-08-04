output "vmss_id" {
  description = "Resource ID of the client scale set. Custom metrics are published against it so autoscale can read them."
  value       = azurerm_linux_virtual_machine_scale_set.client.id
}

output "vmss_name" {
  description = "Name of the client scale set. Nomad node IDs are '<vmss name>_<instance>', so it doubles as the node-ID prefix."
  value       = azurerm_linux_virtual_machine_scale_set.client.name
}
