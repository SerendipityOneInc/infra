variable "prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "identity_id" {
  type = string
}

variable "identity_client_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "lb_backend_pool_ids" {
  type    = list(string)
  default = []
}

variable "cluster_tag_name" {
  type = string
}

variable "cluster_tag_value" {
  type = string
}

variable "storage_account_name" {
  type = string
}

variable "setup_container_name" {
  type = string
}

variable "setup_files_hash" {
  type = map(string)
}

variable "image_id" {
  type    = string
  default = ""
}

variable "cluster_size" {
  type    = number
  default = 1
}

variable "machine_type" {
  type    = string
  default = "Standard_D4as_v5"
}

variable "os_disk_size_gb" {
  type    = number
  default = 40
}

variable "admin_username" {
  type    = string
  default = "e2b"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "node_pool_name" {
  type        = string
  description = "Nomad node pool name for this pool"
}

variable "consul_acl_token" {
  type = string
}

variable "consul_gossip_encryption_key" {
  type = string
}

variable "consul_dns_request_token" {
  type = string
}

variable "acr_login_server" {
  type        = string
  description = "ACR login server (e.g. myregistry.azurecr.io) used for the docker credential helper."
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "scripts_path" {
  type    = string
  default = ""
}
