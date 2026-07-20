#!/usr/bin/env bash
# Runs as VMSS custom_data (executed by cloud-init as user-data). Configures and
# starts Consul + Nomad in client mode for a Firecracker host pool.
#
# Azure port of the SRP-customized GCP client bootstrap
# (iac/provider-gcp/nomad-cluster/scripts/start-client.sh). Covers the same
# responsibilities: local scratch disk for /orchestrator, hugepages, swap,
# sysctl, NBD, fc-* object-storage mounts, JuiceFS (STUBBED on Azure), Consul
# DNS, and the orchestrator-version handshake.

set -euo pipefail

PS4='[\D{%Y-%m-%d %H:%M:%S}] '
set -x

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# ---------------------------------------------------------------------------
# Local scratch disk(s) for /orchestrator
#
# Azure E-ads/D-ads v5 SKUs expose a local temp/resource disk, and some sizes
# expose one or more local NVMe disks. waagent/cloud-init may auto-mount the
# temp disk at /mnt; reclaim it. Prefer local NVMe (RAID0 if several); otherwise
# fall back to the single SCSI temp disk (/dev/sdb). Replaces the GCP
# /dev/disk/by-id/google-local-nvme-ssd-* block.
# ---------------------------------------------------------------------------
MOUNT_POINT="/orchestrator"

if mountpoint -q /mnt; then
  umount /mnt || true
fi
# Stop waagent/fstab from remounting the temp disk at /mnt.
sed -i '\#[[:space:]]/mnt[[:space:]]#d' /etc/fstab || true

# Identify the OS disk so we never format it.
ROOT_SRC="$(findmnt -no SOURCE / || true)"
ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"

# Collect candidate whole disks: local NVMe (preferred).
CANDIDATES=()
while read -r NAME TYPE; do
  [ "$TYPE" = "disk" ] || continue
  { [ "$NAME" = "$ROOT_DISK" ] || [ -z "$NAME" ]; } && continue
  case "$NAME" in
  nvme*) CANDIDATES+=("/dev/$NAME") ;;
  esac
done < <(lsblk -dn -o NAME,TYPE)

# No local NVMe found: fall back to the SCSI temp/resource disk.
if [ "$${#CANDIDATES[@]}" -eq 0 ] && [ -b /dev/sdb ] && [ "$ROOT_DISK" != "sdb" ]; then
  CANDIDATES+=("/dev/sdb")
fi

if [ "$${#CANDIDATES[@]}" -gt 1 ]; then
  echo "Creating RAID0 across $${#CANDIDATES[@]} local disks: $${CANDIDATES[*]}"
  DISK="/dev/md0"
  until mdadm --create --verbose "$DISK" --level=0 --raid-devices="$${#CANDIDATES[@]}" "$${CANDIDATES[@]}"; do
    echo "failed to create array, retrying ..."
    sleep 1
  done
  mkdir -p /etc/mdadm
  mdadm --detail --scan --verbose | tee -a /etc/mdadm/mdadm.conf
elif [ "$${#CANDIDATES[@]}" -eq 1 ]; then
  DISK="$${CANDIDATES[0]}"
else
  echo "ERROR: no local scratch disk found for $MOUNT_POINT"
  exit 1
fi

until mkfs.xfs -f -b size=4096 "$DISK"; do
  echo "failed to make file system, retrying ..."
  sleep 1
done

mkdir -p "$MOUNT_POINT"
echo "$DISK $MOUNT_POINT xfs noatime 0 0" | tee -a /etc/fstab
mount "$MOUNT_POINT"

mkdir -p /orchestrator/sandbox
mkdir -p /orchestrator/template
mkdir -p /orchestrator/build

# Add swapfile
SWAPFILE="/swapfile"
fallocate -l 100G $SWAPFILE
chmod 600 $SWAPFILE
mkswap $SWAPFILE
swapon $SWAPFILE
echo "$SWAPFILE none swap sw 0 0" | tee -a /etc/fstab
sysctl vm.swappiness=10
sysctl vm.vfs_cache_pressure=50

# ---------------------------------------------------------------------------
# TODO(azure-juicefs, Phase C): mount the JuiceFS-backed persistent volume(s)
# here. Azure JuiceFS is a SEPARATE deployment delivered later; do NOT invent
# mount commands. On GCP the client fetches the EE client, runs `juicefs auth`,
# then `juicefs mount <vol> <path> --subdir ... --cache-group ...` with a token
# read from Secret Manager. On Azure the metadata engine, object storage and
# token source are not provisioned yet. The rest of start-client works without
# it.
# ---------------------------------------------------------------------------

# Add tmpfs for snapshotting
mkdir -p /mnt/snapshot-cache
mount -t tmpfs -o size=65G tmpfs /mnt/snapshot-cache

ulimit -n 1048576
export GOMAXPROCS=$(nproc)

tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535

# Increase the maximum number of memory map areas
vm.max_map_count=1048576

# Allow larger host writeback bursts before dirty-page throttling.
vm.dirty_background_ratio=20
vm.dirty_ratio=40

EOF
sysctl -p

echo "Disabling inotify for NBD devices"
# https://lore.kernel.org/lkml/20220422054224.19527-1-matthew.ruffell@canonical.com/
cat <<EOH >/etc/udev/rules.d/97-nbd-device.rules
# Disable inotify watching of change events for NBD devices
ACTION=="add|change", KERNEL=="nbd*", OPTIONS:="nowatch"
EOH

udevadm control --reload-rules
udevadm trigger

# Load the nbd module with 4096 devices
modprobe nbd nbds_max=4096

# Create the directory for the fc mounts
mkdir -p /fc-vm

# ---------------------------------------------------------------------------
# Authenticate the Azure CLI with the attached Managed Identity (replaces the
# AWS instance profile / GCP service account key).
# ---------------------------------------------------------------------------
az login --identity --username "${IDENTITY_CLIENT_ID}" --allow-no-subscriptions >/dev/null 2>&1 ||
  az login --identity >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Mount the fc-* Blob containers read-only via blobfuse2 (replaces gcsfuse /
# s3fs). MSI auth uses the attached user-assigned identity.
#
# TODO(azure-blobfuse): confirm blobfuse2 is baked into the Packer image and
# that MSI auth + allow_other behave as expected. Kept best-effort so a mount
# failure does not abort the whole bootstrap.
# ---------------------------------------------------------------------------
export AZURE_STORAGE_ACCOUNT="${STORAGE_ACCOUNT}"
export AZURE_STORAGE_AUTH_TYPE="msi"
export AZURE_STORAGE_IDENTITY_CLIENT_ID="${IDENTITY_CLIENT_ID}"
export AZURE_STORAGE_ACCOUNT_CONTAINER=""

mount_blob_container() {
  local container="$1"
  local mount_dir="$2"
  local cache_dir="/blobfuse-cache/$container"
  mkdir -p "$mount_dir" "$cache_dir"
  blobfuse2 mount "$mount_dir" \
    --container-name="$container" \
    --tmp-path="$cache_dir" \
    --read-only=true \
    -o allow_other || echo "WARN: blobfuse2 mount of $container failed"
}

mount_blob_container "${FC_ENV_PIPELINE_CONTAINER}" /fc-envd
mount_blob_container "${FC_KERNELS_CONTAINER}" /fc-kernels
mount_blob_container "${FC_VERSIONS_CONTAINER}" /fc-versions
mount_blob_container "${FC_BUSYBOX_CONTAINER}" /fc-busybox

# Download the Consul/Nomad runner scripts from the setup Blob container.
az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-consul-${RUN_CONSUL_FILE_HASH}.sh" --file /opt/consul/bin/run-consul.sh --auth-mode login --no-progress
az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-nomad-${RUN_NOMAD_FILE_HASH}.sh" --file /opt/nomad/bin/run-nomad.sh --auth-mode login --no-progress

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

# Docker auth for ACR via the acr-env credential helper (uses Managed Identity).
# TODO(azure-acr): docker-credential-acr-env must be baked into the Packer image
# (mirrors the AWS ecr-login helper dependency).
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
DNSStubListener=yes
DNSStubListenerExtra=172.17.0.1
EOF
sync

# Set up huge pages (allocated early, before memory fragments).
echo "[Setting up huge pages]"
mkdir -p /mnt/hugepages
mount -t hugetlbfs none /mnt/hugepages

available_ram=$(grep MemTotal /proc/meminfo | awk '{print $2}') # in KiB
available_ram=$(($available_ram / 1024))                        # in MiB
echo "- Total memory: $available_ram MiB"

min_normal_ram=$((4 * 1024))                             # 4 GiB
min_normal_percentage_ram=$(($available_ram * 16 / 100)) # 16% of the total memory
max_normal_ram=$((42 * 1024))                            # 42 GiB

max() {
  if (($1 > $2)); then echo "$1"; else echo "$2"; fi
}
min() {
  if (($1 < $2)); then echo "$1"; else echo "$2"; fi
}
ensure_even() {
  if (($1 % 2 == 0)); then echo "$1"; else echo $(($1 - 1)); fi
}
remove_decimal() {
  echo "$(echo $1 | sed 's/\..*//')"
}

reserved_normal_ram=$(max $min_normal_ram $min_normal_percentage_ram)
reserved_normal_ram=$(min $reserved_normal_ram $max_normal_ram)
echo "- Reserved RAM: $reserved_normal_ram MiB"

hugepages_ram=$(($available_ram - $reserved_normal_ram))
hugepages_ram=$(remove_decimal $hugepages_ram)
hugepages_ram=$(ensure_even $hugepages_ram)
echo "- RAM for hugepages: $hugepages_ram MiB"

hugepage_size_in_mib=2
hugepages=$(($hugepages_ram / $hugepage_size_in_mib))

base_hugepages_percentage=${BASE_HUGEPAGES_PERCENTAGE}
base_hugepages=$(($hugepages * $base_hugepages_percentage / 100))
base_hugepages=$(remove_decimal $base_hugepages)
echo "- Allocating $base_hugepages huge pages ($base_hugepages_percentage%) for base usage"
echo $base_hugepages >/proc/sys/vm/nr_hugepages

overcommitment_hugepages_percentage=$((100 - $base_hugepages_percentage))
overcommitment_hugepages=$(($hugepages * $overcommitment_hugepages_percentage / 100))
overcommitment_hugepages=$(remove_decimal $overcommitment_hugepages)
echo "- Allocating $overcommitment_hugepages huge pages ($overcommitment_hugepages_percentage%) for overcommitment"
echo $overcommitment_hugepages >/proc/sys/vm/nr_overcommit_hugepages

# Azure platform DNS (wire-server) used as the Consul recursor so Consul can
# resolve both .consul and internet queries.
AZURE_DNS="168.63.129.16"

/opt/consul/bin/run-consul.sh --client \
  --consul-token "${CONSUL_TOKEN}" \
  --cluster-tag-name "${CLUSTER_TAG_NAME}" \
  --cluster-tag-value "${CLUSTER_TAG_VALUE}" \
  --enable-gossip-encryption \
  --gossip-encryption-key "${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
  --dns-request-token "${CONSUL_DNS_REQUEST_TOKEN}" \
  --recursor "$AZURE_DNS" &

# Wait for Consul DNS on port 8600.
echo "- Waiting for Consul DNS to start on port 8600..."
for i in {1..60}; do
  if nc -z 127.0.0.1 8600 2>/dev/null; then
    echo "- Consul DNS is ready (attempt $i/60)"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "- ERROR: Consul DNS not responding after 60 seconds, exiting..."
    exit 1
  fi
  sleep 1
done

echo "[Configuring systemd-resolved for Consul DNS]"
systemctl restart systemd-resolved
for i in {1..60}; do
  if host google.com 2>/dev/null; then
    echo "- DNS resolving is ready (attempt $i/60)"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "- ERROR: Systemd-resolved not responding after 60 seconds, exiting..."
    exit 1
  fi
  sleep 1
done
resolvectl flush-caches

%{ if SET_ORCHESTRATOR_VERSION_METADATA == "true" }
# Orchestrator-version handshake: fetch the pinned orchestrator job version from
# a Nomad variable before starting the Nomad client. The node cannot start
# without it.
FETCH_TIMEOUT_SECONDS=600
FETCH_INTERVAL_SECONDS=5
FETCH_MAX_ATTEMPTS=$((FETCH_TIMEOUT_SECONDS / FETCH_INTERVAL_SECONDS + 1))

echo "[Fetching orchestrator version from Nomad servers (timeout: $${FETCH_TIMEOUT_SECONDS}s)]"
ORCHESTRATOR_VERSION=""
for i in $(seq 1 $FETCH_MAX_ATTEMPTS); do
  ELAPSED=$(((i - 1) * FETCH_INTERVAL_SECONDS))
  NOMAD_SERVER=$(dig +short nomad.service.consul | head -1)
  if [ -z "$NOMAD_SERVER" ]; then
    echo "- Waiting for Consul DNS (nomad.service.consul)... ($${ELAPSED}s / $${FETCH_TIMEOUT_SECONDS}s)"
  else
    API_RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -H "X-Nomad-Token: ${NOMAD_TOKEN}" \
      "http://$NOMAD_SERVER:4646/v1/var/nomad/jobs" 2>/dev/null)
    if echo "$API_RESPONSE" | jq -e '.Items.latest_orchestrator_job_id' >/dev/null 2>&1; then
      ORCHESTRATOR_VERSION=$(echo "$API_RESPONSE" | jq -r '.Items.latest_orchestrator_job_id')
      echo "- Fetched orchestrator version: $ORCHESTRATOR_VERSION"
      break
    elif [ -n "$API_RESPONSE" ]; then
      echo "- Invalid response from Nomad API, retrying... ($${ELAPSED}s / $${FETCH_TIMEOUT_SECONDS}s)"
    else
      echo "- No response from Nomad API at $${NOMAD_SERVER}, retrying... ($${ELAPSED}s / $${FETCH_TIMEOUT_SECONDS}s)"
    fi
  fi
  if [ $i -eq $FETCH_MAX_ATTEMPTS ]; then
    echo "- ERROR: Could not fetch orchestrator version from Nomad servers after $${FETCH_TIMEOUT_SECONDS}s"
    exit 1
  fi
  sleep $FETCH_INTERVAL_SECONDS
done

/opt/nomad/bin/run-nomad.sh --client --consul-token "${CONSUL_TOKEN}" --node-pool "${NODE_POOL}" --node-labels "${NODE_LABELS}" --orchestrator-job-version "$ORCHESTRATOR_VERSION" &
%{ else }
/opt/nomad/bin/run-nomad.sh --client --consul-token "${CONSUL_TOKEN}" --node-pool "${NODE_POOL}" --node-labels "${NODE_LABELS}" &
%{ endif }

# Add alias for ssh-ing to sbx
echo '_sbx_ssh() {
  local address=$(dig @127.0.0.4 $1. A +short 2>/dev/null)
  ssh -o StrictHostKeyChecking=accept-new "root@$address"
}

alias sbx-ssh=_sbx_ssh' >>/etc/profile
