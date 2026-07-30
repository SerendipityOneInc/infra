variable "node_pool" {
  type = string
}

variable "memory_max_mb" {
  type        = number
  description = <<-EOT
    Nomad memory_max for the template-manager task, in MiB. -1 (the default,
    and the historical behaviour) lets it oversubscribe without bound, so a
    burst of concurrent builds exhausts the whole build node and Firecracker
    restores start failing with "mmap memfd: cannot allocate memory". Setting
    a ceiling below node memory makes Nomad kill the task instead, which fails
    loudly rather than taking the node down with it.
  EOT
  default     = -1
}

variable "port" {
  type = number
}

variable "update_stanza" {
  type        = bool
  description = "Enable scaling, update block, and extended kill_timeout"
}

variable "artifact_source" {
  type        = string
  description = "Full artifact URL for the template-manager binary (e.g. gcs::https://... or s3::https://...)"
}

// Nomad API access for job count query
variable "nomad_addr" {
  type        = string
  description = "Nomad API address (e.g. https://nomad.example.com)"
}

variable "nomad_token" {
  type      = string
  sensitive = true
}

variable "job_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}
