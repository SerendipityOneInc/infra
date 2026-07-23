#!/usr/bin/env bash
# Runs as VMSS custom_data (executed by cloud-init as user-data). Configures and
# starts Consul + Nomad in client mode for the API node pool. Mirrors
# provider-aws nodepool-api/start-api.sh, Azure-ised.

set -euo pipefail

PS4='[\D{%Y-%m-%d %H:%M:%S}] '
set -x

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

ulimit -n 1048576
export GOMAXPROCS=$(nproc)

sudo tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535
EOF
sudo sysctl -p

# Authenticate the Azure CLI with the attached Managed Identity (replaces the
# AWS instance profile) so blob/keyvault/acr calls use MSI.
az login --identity --username "${IDENTITY_CLIENT_ID}" --allow-no-subscriptions >/dev/null 2>&1 || \
  az login --identity >/dev/null 2>&1

az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-consul-${RUN_CONSUL_FILE_HASH}.sh" --file /opt/consul/bin/run-consul.sh --auth-mode login --no-progress
az storage blob download --account-name "${STORAGE_ACCOUNT}" --container-name "${SETUP_CONTAINER}" \
  --name "run-nomad-${RUN_NOMAD_FILE_HASH}.sh" --file /opt/nomad/bin/run-nomad.sh --auth-mode login --no-progress

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

# ACR docker auth is set up by run-nomad.sh (--acr-login-server below): it mints
# a static auth from the MSI-backed acr-env helper + installs a refresh timer.
# Nomad's docker driver only honours static auths, not credential helpers.
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

# Persistent host dir for Traefik's ACME cert store (survives ingress reschedules
# so Let's Encrypt isn't re-hit each time). Exposed to Nomad as host_volume "traefik-acme".
mkdir -p /opt/traefik-acme
chmod 700 /opt/traefik-acme

/opt/nomad/bin/run-nomad.sh --client --consul-token "${CONSUL_TOKEN}" --node-pool "${NODE_POOL}" --acr-login-server "${ACR_LOGIN_SERVER}" --host-volume "traefik-acme:/opt/traefik-acme" &
