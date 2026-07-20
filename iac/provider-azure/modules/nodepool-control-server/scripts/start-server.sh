#!/bin/bash
# Runs as VMSS custom_data (executed by cloud-init as user-data on the Ubuntu
# Gen2 image). Uses run-consul / run-nomad to configure and start Consul and
# Nomad in server mode. Assumes a Packer-built image mirroring provider-aws.

set -e

# Send the log output from this script to user-data.log, syslog, and the console.
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

ulimit -n 65536
export GOMAXPROCS=$(nproc)

# Authenticate the Azure CLI with the attached user-assigned Managed Identity so
# `az storage blob download` works (replaces the AWS instance profile + s3 cp).
az login --identity --username "${IDENTITY_CLIENT_ID}" --allow-no-subscriptions >/dev/null 2>&1 || \
  az login --identity >/dev/null 2>&1

# Download the Consul/Nomad runner scripts from the setup Blob container.
az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-consul-${RUN_CONSUL_FILE_HASH}.sh" --file /opt/consul/bin/run-consul.sh --auth-mode login --no-progress
az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-nomad-${RUN_NOMAD_FILE_HASH}.sh" --file /opt/nomad/bin/run-nomad.sh --auth-mode login --no-progress

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

/opt/consul/bin/run-consul.sh --server --server-scale-set-name "${SERVER_SCALE_SET_NAME}" --consul-token "${CONSUL_TOKEN}" --enable-gossip-encryption --gossip-encryption-key "${CONSUL_GOSSIP_ENCRYPTION_KEY}"
/opt/nomad/bin/run-nomad.sh --server --num-servers "${NUM_SERVERS}" --consul-token "${CONSUL_TOKEN}" --nomad-token "${NOMAD_TOKEN}"
