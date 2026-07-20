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

variable "data_disk_size_gb" {
  type        = number
  default     = 100
  description = "Size of the persistent managed data disk for ClickHouse data."
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
  type = string
}

variable "job_constraint_prefix" {
  type        = string
  description = "Prefix for the job-constraint tag used to pin ClickHouse Nomad jobs to these nodes."
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
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "scripts_path" {
  type    = string
  default = ""
}
