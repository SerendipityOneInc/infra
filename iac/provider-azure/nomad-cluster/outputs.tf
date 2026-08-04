output "client_vmss_id" {
  description = "Resource ID of the client scale set, for publishing autoscale custom metrics against it."
  value       = module.client.vmss_id
}

output "client_vmss_name" {
  description = "Name of the client scale set, which is also the prefix of its Nomad node IDs."
  value       = module.client.vmss_name
}
