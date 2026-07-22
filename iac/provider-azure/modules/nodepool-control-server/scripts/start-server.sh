#!/bin/bash
# Runs as VMSS custom_data (executed by cloud-init as user-data on the Ubuntu
# Gen2 image). Uses run-consul / run-nomad to configure and start Consul and
# Nomad in server mode. Assumes a Packer-built image mirroring provider-aws.

set -e

# Send the log output from this script to user-data.log, syslog, and the console.
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

ulimit -n 65536
export GOMAXPROCS=$(nproc)

# ---------------------------------------------------------------------------
# Persistent raft state: mount the VMSS data disk (lun 0) and point the Consul
# and Nomad data dirs at it. Azure reimage (explicit or the azurerm provider's
# automatic reimage_on_manual_upgrade roll) resets ONLY the OS disk, so the
# raft state survives and a reimaged server rejoins the cluster with its
# identity + data intact — no lost jobs, no mixed-generation quorum deadlock.
# The stable /dev/disk/azure/scsi1/lunN path avoids sdX name races; only format
# when the disk carries no filesystem yet (first boot of a fresh disk).
# ---------------------------------------------------------------------------
STATE_DEV="/dev/disk/azure/scsi1/lun0"
STATE_MNT="/var/lib/e2b-state"
for _i in $(seq 1 30); do [ -e "$STATE_DEV" ] && break; sleep 2; done
if [ ! -e "$STATE_DEV" ]; then
  echo "FATAL: state data disk $STATE_DEV not found" >&2
  exit 1
fi
if ! blkid "$STATE_DEV" >/dev/null 2>&1; then
  mkfs.ext4 -L e2b-state "$STATE_DEV"
fi
mkdir -p "$STATE_MNT"
mountpoint -q "$STATE_MNT" || mount "$STATE_DEV" "$STATE_MNT"
mkdir -p "$STATE_MNT/consul" "$STATE_MNT/nomad"
# Preserve the ownership the packer image gave the original data dirs, then
# replace them with symlinks (rm -rf first: ln -sfn into an existing dir nests).
chown --reference=/opt/consul/data "$STATE_MNT/consul" 2>/dev/null || true
chown --reference=/opt/nomad/data "$STATE_MNT/nomad" 2>/dev/null || true
rm -rf /opt/consul/data /opt/nomad/data
ln -s "$STATE_MNT/consul" /opt/consul/data
ln -s "$STATE_MNT/nomad" /opt/nomad/data

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
