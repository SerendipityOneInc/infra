locals {
  job_env_vars = {
    for key, value in var.job_env_vars : key => trimspace(value)
    if try(trimspace(value), "") != ""
  }
}

resource "nomad_job" "billing" {
  jobspec = templatefile("${path.module}/jobs/billing.hcl", {
    node_pool     = var.node_pool
    image_name    = var.image
    count         = var.count_instances
    update_stanza = var.update_stanza
    job_env_vars  = local.job_env_vars
  })
}
