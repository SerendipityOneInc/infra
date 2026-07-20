packer {
  required_version = ">=1.8.4"

  required_plugins {
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}

source "azure-arm" "orch" {
  # --- Authentication ---
  # Use the Azure CLI session by default (matches the Makefile / terraform flow);
  # fall back to service-principal auth when a client_id is provided.
  subscription_id    = var.subscription_id
  tenant_id          = var.tenant_id
  client_id          = var.client_id
  client_secret      = var.client_secret
  use_azure_cli_auth = var.client_id == ""

  # --- Base marketplace image: Ubuntu 22.04 Jammy, Gen2 ---
  os_type         = "Linux"
  image_publisher = var.image_publisher
  image_offer     = var.image_offer
  image_sku       = var.image_sku

  # --- Build VM (no nested virt needed on the builder) ---
  location     = var.location
  vm_size      = var.base_vm_size
  ssh_username = "packer"

  # --- Output: publish directly to an Azure Compute Gallery (Shared Image
  # Gallery). The image definition (image_name) must already exist in the gallery
  # as a Gen2 (hyperVGeneration V2), Linux definition. ---
  shared_image_gallery_destination {
    subscription   = var.subscription_id
    resource_group = var.gallery_resource_group
    gallery_name   = var.gallery_name
    image_name     = var.image_name
    image_version  = var.image_version

    storage_account_type = "Standard_LRS"

    target_region {
      name = var.location
    }
  }

  azure_tags = {
    app       = "e2b"
    terraform = "false"
    packer    = "true"
    prefix    = var.prefix
  }
}

locals {
  # The shared provisioner scripts are cloud-agnostic and reused verbatim from
  # the shared setup directory (same scripts AWS and GCP provision).
  shared_setup_dir = "${path.root}/../../nomad-cluster-disk-image/setup"
}

build {
  sources = ["source.azure-arm.orch"]

  provisioner "file" {
    source      = "${local.shared_setup_dir}/supervisord.conf"
    destination = "/tmp/supervisord.conf"
  }

  provisioner "file" {
    source      = "${local.shared_setup_dir}"
    destination = "/tmp"
  }

  provisioner "file" {
    source      = "${local.shared_setup_dir}/daemon.json"
    destination = "/tmp/daemon.json"
  }

  provisioner "file" {
    source      = "${local.shared_setup_dir}/limits.conf"
    destination = "/tmp/limits.conf"
  }

  # Install Docker
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/docker",
      "sudo mv /tmp/daemon.json /etc/docker/daemon.json",
      "sudo curl -fsSL https://get.docker.com -o get-docker.sh",
      "sudo sh get-docker.sh",
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y unzip jq net-tools qemu-utils make build-essential openssh-client openssh-server", # TODO: openssh-server is updated to prevent security vulnerabilities
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo apt-get -y update",
      "sudo apt-get install -y nfs-common",
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo systemctl start docker",
      "sudo usermod -aG docker $USER",
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/gruntwork",
      "git clone --branch v0.1.3 https://github.com/gruntwork-io/bash-commons.git /tmp/bash-commons",
      "sudo cp -r /tmp/bash-commons/modules/bash-commons/src /opt/gruntwork/bash-commons",
    ]
  }

  provisioner "shell" {
    script          = "${local.shared_setup_dir}/install-consul.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.consul_version}"
  }

  provisioner "shell" {
    script          = "${local.shared_setup_dir}/install-nomad.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.nomad_version}"
  }

  # Install the ClickHouse client at the same version as the server so it's
  # available on every node without being downloaded at boot time.
  provisioner "shell" {
    script          = "${local.shared_setup_dir}/install-clickhouse-client.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.clickhouse_client_version}"
  }

  # Install CNI plugins (needed by Nomad bridge-mode networking on the
  # ClickHouse nodepool). Harmless on nodes that don't use them.
  provisioner "shell" {
    script          = "${local.shared_setup_dir}/install-cni-plugins.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.cni_plugin_version}"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/nomad/plugins",
    ]
  }

  # Install the Azure CLI (used by node bootstrap / operators; parallels the AWS
  # CLI install in the amazon-ebs build).
  provisioner "shell" {
    inline = [
      "curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash",
    ]
  }

  # Install the Azure ACR docker credential helper (replaces
  # amazon-ecr-credential-helper). Lets the Docker daemon pull from
  # <registry>.azurecr.io using the VMSS user-assigned Managed Identity.
  # https://github.com/chrismellard/docker-credential-acr-env
  provisioner "shell" {
    inline = [
      "curl -fsSL -o /tmp/acr-env.tar.gz https://github.com/chrismellard/docker-credential-acr-env/releases/download/${var.acr_cred_helper_version}/docker-credential-acr-env_${var.acr_cred_helper_version}_linux_amd64.tar.gz",
      "sudo tar -xzf /tmp/acr-env.tar.gz -C /usr/local/bin docker-credential-acr-env",
      "sudo chmod +x /usr/local/bin/docker-credential-acr-env",
      "rm -f /tmp/acr-env.tar.gz",
    ]
  }

  # Install blobfuse2 (Azure Blob Storage FUSE mount tool; replaces s3fs/gcsfuse).
  # Uses the Microsoft packages repo for Ubuntu 22.04.
  # https://learn.microsoft.com/azure/storage/blobs/blobfuse2-how-to-deploy
  provisioner "shell" {
    inline_shebang = "/bin/bash"
    inline = [
      "set -eo pipefail",
      "curl -fsSL -o /tmp/packages-microsoft-prod.deb https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb",
      "sudo dpkg -i /tmp/packages-microsoft-prod.deb",
      "rm -f /tmp/packages-microsoft-prod.deb",
      "sudo apt-get update",
      "sudo apt-get install -y blobfuse2 fuse3",
    ]
  }

  provisioner "shell" {
    inline = [
      # Increase the maximum number of open files
      "sudo mv /tmp/limits.conf /etc/security/limits.conf",
      # Increase the maximum number of connections by 4x
      "echo 'net.netfilter.nf_conntrack_max = 2097152' | sudo tee -a /etc/sysctl.conf",
    ]
  }

  # Deprovision the Azure Linux agent so the captured image generalizes cleanly.
  # Required by the azure-arm builder when publishing a generalized gallery image.
  provisioner "shell" {
    inline = [
      "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync",
    ]
    inline_shebang    = "/bin/sh -x"
    execute_command   = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    expect_disconnect = true
  }
}
