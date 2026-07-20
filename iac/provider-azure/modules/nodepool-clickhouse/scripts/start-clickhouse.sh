#!/usr/bin/env bash
# Runs as VMSS custom_data. Mounts the persistent data disk, then configures and
# starts Consul + Nomad in client mode for the ClickHouse pool. Mirrors
# provider-aws nodepool-clickhouse/start-clickhouse.sh, Azure-ised.

set -euo pipefail

PS4='[\D{%Y-%m-%d %H:%M:%S}] '
set -x

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

ulimit -n 1048576

# --- Mount the persistent managed data disk (lun 0) ---
# Azure exposes attached data disks under /dev/disk/azure/scsi1/lunN.
MOUNT_POINT="/clickhouse"
DISK="/dev/disk/azure/scsi1/lun0"
TIMEOUT=300
INTERVAL=5

echo "Waiting for data disk $DISK to appear..."
SECONDS_WAITED=0
while [[ $SECONDS_WAITED -lt $TIMEOUT ]]; do
  if [[ -e "$DISK" ]]; then
    echo "Found data disk: $(readlink -f "$DISK")"
    break
  fi
  sleep $INTERVAL
  SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL))
done

if [[ ! -e "$DISK" ]]; then
  echo "ERROR: data disk $DISK not found after $${TIMEOUT}s"
  exit 1
fi

# Resolve to the real device node before formatting/mounting.
DISK="$(readlink -f "$DISK")"

if ! blkid "$DISK"; then
  echo "No filesystem found on $DISK, creating XFS filesystem..."
  mkfs.xfs -f -b size=4096 "$DISK"
fi

mkdir -p "$MOUNT_POINT"
mount -o noatime "$DISK" "$MOUNT_POINT"
echo "Mounted $DISK at $MOUNT_POINT"
# ---------------------------------------------------------

sudo tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535
EOF
sudo sysctl -p

# Authenticate the Azure CLI with the attached Managed Identity.
az login --identity --username "${IDENTITY_CLIENT_ID}" --allow-no-subscriptions >/dev/null 2>&1 || \
  az login --identity >/dev/null 2>&1

az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-consul-${RUN_CONSUL_FILE_HASH}.sh" --file /opt/consul/bin/run-consul.sh --auth-mode login --no-progress
az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-nomad-${RUN_NOMAD_FILE_HASH}.sh" --file /opt/nomad/bin/run-nomad.sh --auth-mode login --no-progress

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

# TODO(azure-acr): docker-credential-acr-env must be baked into the Packer image.
mkdir -p /root/docker
cat <<EOF >/root/docker/config.json
{
    "credHelpers": {
        "${ACR_LOGIN_SERVER}": "acr-env"
    }
}
EOF

mkdir -p /etc/systemd/resolved.conf.d/
cat <<EOF >/etc/systemd/resolved.conf.d/consul.conf
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
DNSStubListener=yes
DNSStubListenerExtra=172.17.0.1
EOF
systemctl restart systemd-resolved

/opt/consul/bin/run-consul.sh --client \
    --consul-token "${CONSUL_TOKEN}" \
    --server-scale-set-name "${SERVER_SCALE_SET_NAME}" \
    --enable-gossip-encryption \
    --gossip-encryption-key "${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
    --dns-request-token "${CONSUL_DNS_REQUEST_TOKEN}" &

/opt/nomad/bin/run-nomad.sh --client --consul-token "${CONSUL_TOKEN}" --node-pool "${NODE_POOL}" &
