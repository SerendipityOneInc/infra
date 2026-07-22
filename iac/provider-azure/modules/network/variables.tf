variable "prefix" {
  type        = string
  description = "Name prefix for all resources"
  default     = "e2b-"
}

variable "resource_group_name" {
  type        = string
  description = "The resource group that holds the network resources"
}

variable "location" {
  type        = string
  description = "The Azure region for all resources"
}

variable "tags" {
  type        = map(string)
  description = "Tags to attach to resources created by this module"
  default     = {}
}

# ---
# Address space
# ---
variable "existing_vnet_name" {
  type        = string
  description = "Name of an existing VNet to add the e2b subnets to (co-locate on a shared VNet to reach private-endpoint services). Empty = create a dedicated VNet from vnet_address_space."
  default     = ""
}

variable "existing_vnet_resource_group" {
  type        = string
  description = "Resource group of existing_vnet_name (may differ from the e2b resource group). Ignored when existing_vnet_name is empty."
  default     = ""
}

variable "vnet_address_space" {
  type        = list(string)
  description = "CIDR block(s) for the virtual network (only used when existing_vnet_name is empty)"
  default     = ["10.0.0.0/16"]
}

variable "cluster_subnet_cidr" {
  type        = string
  description = "CIDR for the subnet that holds the cluster nodes (server/api/client/build VMSS). Egress via NAT gateway, guarded by the cluster NSG."
  default     = "10.0.0.0/20"
}

variable "services_subnet_cidr" {
  type        = string
  description = "CIDR for the auxiliary services subnet (e.g. private endpoints, databases). Also egresses via the NAT gateway."
  default     = "10.0.16.0/20"
}

# ---
# In-cluster ingress (client-proxy VMSS) ports. The L4 load balancer forwards
# raw TCP to these ports; the in-cluster ingress terminates TLS and does all L7
# host/path routing.
# ---
variable "ingress_https_port" {
  type        = number
  description = "Backend TCP port on the ingress/client-proxy nodes that terminates TLS (frontend 443 forwards here)"
  default     = 443
}

variable "ingress_http_port" {
  type        = number
  description = "Backend TCP port on the ingress/client-proxy nodes serving plain HTTP (frontend 80 forwards here, used for redirects / ACME)"
  default     = 80
}

variable "public_cert_name" {
  type        = string
  description = "Key Vault certificate name (issued/renewed by keyvault-acmebot) whose backing secret the App Gateway references versionlessly for automatic rotation."
}

variable "ingress_backend_port" {
  type        = number
  description = "TCP port the in-cluster Traefik ingress entrypoint listens on (job-ingress ingress_port). The App Gateway forwards the default (api./sandbox/docker.) + grpc-api. traffic here; Traefik then does dynamic host-based routing (api service, sandboxes via Consul catalog). Traefik serves /ping on this port for the health probe. Must equal local.ingress_port in provider-azure/main.tf."
  default     = 8080
}

# ---
# Load balancer health probe. Mirrors the AWS ALB target-group health check
# (path /ping) and the GCP client-proxy health check.
# ---
variable "health_probe_protocol" {
  type        = string
  description = "Protocol for the LB health probe: Tcp, Http, or Https"
  default     = "Http"

  validation {
    condition     = contains(["Tcp", "Http", "Https"], var.health_probe_protocol)
    error_message = "health_probe_protocol must be one of Tcp, Http, Https."
  }
}

variable "health_probe_port" {
  type        = number
  description = "Port the LB health probe targets on the backend nodes"
  default     = 8080
}

variable "health_probe_path" {
  type        = string
  description = "Request path for Http/Https health probes (ignored for Tcp)"
  default     = "/ping"
}

variable "health_probe_interval_seconds" {
  type        = number
  description = "Interval between LB health probes"
  default     = 5
}

variable "health_probe_number_of_probes" {
  type        = number
  description = "Consecutive probe failures before a backend node is taken out of rotation"
  default     = 2
}

# ---
# Management access
# ---
variable "ssh_allowed_source" {
  type        = string
  description = "Source address prefix (CIDR, '*'/'Internet', or a service tag like 'VirtualNetwork') permitted to reach SSH (22) on the cluster nodes. Mirrors the GCP internal-remote-connection firewall (IAP range in prod, open in dev)."
  default     = "VirtualNetwork"
}

variable "nomad_api_port" {
  type        = number
  description = "Nomad HTTP API/UI port. The Application Gateway host-routes nomad.<domain> straight to the control-server pool on this port (bypasses the in-cluster ingress so the API is reachable before any Nomad job runs, and as a stable control-plane endpoint)."
  default     = 4646
}

# ---
# Application Gateway v2
# ---
variable "domain_name" {
  type        = string
  description = "The domain (or subdomain) where e2b runs. Used for the self-signed origin cert (apex + wildcard) and the App Gateway host-based listeners (nomad.<domain>, grpc-api.<domain>)."
}

variable "appgw_subnet_cidr" {
  type        = string
  description = "CIDR for the dedicated Application Gateway v2 subnet. App Gateway v2 requires its own subnet (no other resources), separate from the cluster/services subnets."
  default     = "10.180.160.0/24"
}

variable "key_vault_name" {
  type        = string
  description = "Key Vault holding the App Gateway origin certificate secrets (appgw-origin-cert / appgw-origin-key)."
}
