variable "node_pool" {
  type = string
}

variable "image" {
  type = string
}

variable "count_instances" {
  type = number
}

variable "update_stanza" {
  type = bool
}

variable "job_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}
