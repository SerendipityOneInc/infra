#!/bin/bash
# Configure and run Consul on an Azure VMSS instance. Azure port of the
# provider-aws run-consul.sh: instance facts come from Azure IMDS and cluster
# discovery uses Consul's Azure cloud auto-join.

set -e
set -x

readonly CONSUL_CONFIG_FILE="default.json"
readonly SYSTEMD_CONFIG_PATH="/etc/systemd/system/consul.service"

# Azure Instance Metadata Service (IMDS).
readonly IMDS_URL="http://169.254.169.254/metadata/instance?api-version=2021-02-01"

readonly DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS="true"
readonly DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD="200ms"
readonly DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS="250"
readonly DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME="10s"
readonly DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION="false"

function log {
  local -r level="$1"
  local -r message="$2"
  echo >&2 -e "$(date +"%Y-%m-%d %H:%M:%S") [${level}] [run-consul] ${message}"
}
function log_info { log "INFO" "$1"; }
function log_warn { log "WARN" "$1"; }
function log_error { log "ERROR" "$1"; }

function assert_not_empty {
  if [[ -z "$2" ]]; then
    log_error "The value for '$1' cannot be empty"
    exit 1
  fi
}

# Fetch the full IMDS instance document once.
IMDS_DOC=""
function imds_doc {
  if [[ -z "$IMDS_DOC" ]]; then
    IMDS_DOC=$(curl -s -H "Metadata:true" --connect-timeout 2 --max-time 5 "$IMDS_URL")
  fi
  echo "$IMDS_DOC"
}

function get_instance_name { imds_doc | jq -r '.compute.name'; }
function get_instance_ip_address { imds_doc | jq -r '.network.interface[0].ipv4.ipAddress[0].privateIpAddress'; }
function get_instance_location { imds_doc | jq -r '.compute.location'; }
function get_instance_zone { imds_doc | jq -r '.compute.zone // empty'; }
function get_subscription_id { imds_doc | jq -r '.compute.subscriptionId'; }
function get_resource_group { imds_doc | jq -r '.compute.resourceGroupName'; }

# Read a VMSS instance tag value by name from IMDS tagsList.
function get_instance_tag_value {
  local -r key="$1"
  imds_doc | jq -r --arg k "$key" '.compute.tagsList[]? | select(.name == $k) | .value' | head -1
}

function generate_consul_config {
  local -r server="${1}"
  local -r consul_token="${2}"
  local -r config_dir="${3}"
  local -r user="${4}"
  local -r server_scale_set_name="${5}"
  local -r datacenter="${6}"
  local -r enable_gossip_encryption="${7}"
  local -r gossip_encryption_key="${8}"
  local -r config_path="$config_dir/$CONSUL_CONFIG_FILE"

  shift 8
  local -ar recursors=("$@")

  local instance_name instance_ip_address subscription_id resource_group
  instance_ip_address=$(get_instance_ip_address)
  instance_name=$(get_instance_name)
  subscription_id=$(get_subscription_id)
  resource_group=$(get_resource_group)

  # Consul Azure cloud auto-join. Every pool (servers and clients alike)
  # discovers the Nomad/Consul SERVER VMSS instances by scale-set name. Azure
  # VMSS instance NICs do NOT carry the VMSS tags, so go-discover's tag mode
  # cannot see them — we must use resource_group + vm_scale_set. Auth is the
  # attached user-assigned managed identity, which needs Reader over the scope
  # (Microsoft.Compute/virtualMachineScaleSets/networkInterfaces/read).
  # https://developer.hashicorp.com/consul/docs/install/cloud-auto-join#microsoft-azure
  local retry_join_json=""
  if [[ -z "$server_scale_set_name" ]]; then
    log_warn "server scale set name empty; skipping auto-join."
  else
    retry_join_json="\"retry_join\": [\"provider=azure subscription_id=$subscription_id resource_group=$resource_group vm_scale_set=$server_scale_set_name\"],"
  fi

  local recursors_config=""
  if [[ ${#recursors[@]} -ne 0 ]]; then
    recursors_config="\"recursors\" : [ "
    for recursor in "${recursors[@]}"; do
      recursors_config="${recursors_config}\"${recursor}\", "
    done
    recursors_config=$(echo "${recursors_config}" | sed 's/, $//')" ],"
  fi

  local bootstrap_expect=""
  local ui="false"
  if [[ "$server" == "true" ]]; then
    local cluster_size
    cluster_size=$(get_instance_tag_value "cluster-size")
    bootstrap_expect="\"bootstrap_expect\": $cluster_size,"
    ui="true"
  fi

  local gossip_encryption_configuration=""
  if [[ "$enable_gossip_encryption" == "true" && -n "$gossip_encryption_key" ]]; then
    gossip_encryption_configuration="\"encrypt\": \"$gossip_encryption_key\","
  fi

  local autopilot_configuration
  autopilot_configuration=$(
    cat <<EOF
"autopilot": {
  "cleanup_dead_servers": $DEFAULT_AUTOPILOT_CLEANUP_DEAD_SERVERS,
  "last_contact_threshold": "$DEFAULT_AUTOPILOT_LAST_CONTACT_THRESHOLD",
  "max_trailing_logs": $DEFAULT_AUTOPILOT_MAX_TRAILING_LOGS,
  "server_stabilization_time": "$DEFAULT_AUTOPILOT_SERVER_STABILIZATION_TIME",
  "disable_upgrade_migration": $DEFAULT_AUTOPILOT_DISABLE_UPGRADE_MIGRATION
},
EOF
  )

  log_info "Creating Consul config in $config_path"
  cat >"$config_path" <<EOF
{
  "connect": { "enabled": true },
  "acl": {
    "enabled": true,
    "default_policy": "deny",
    "enable_token_persistence": true,
    "tokens": { "default": "$consul_token" }
  },
  "telemetry": { "prometheus_retention_time": "2h", "disable_hostname": true },
  "limits": { "http_max_conns_per_client": 80 },
  "advertise_addr": "$instance_ip_address",
  "bind_addr": "$instance_ip_address",
  $bootstrap_expect
  "client_addr": "0.0.0.0",
  "datacenter": "$datacenter",
  "node_name": "$instance_name",
  "leave_on_terminate": true,
  "skip_leave_on_interrupt": true,
  $recursors_config
  $retry_join_json
  "server": $server,
  $gossip_encryption_configuration
  $autopilot_configuration
  "ui": $ui
}
EOF
  chown "$user:$user" "$config_path"
}

function generate_systemd_config {
  local -r systemd_config_path="$1"
  local -r consul_config_dir="$2"
  local -r consul_data_dir="$3"
  local -r consul_bin_dir="$4"
  local -r consul_user="$5"
  local -r config_path="$consul_config_dir/$CONSUL_CONFIG_FILE"

  log_info "Creating systemd config in $systemd_config_path"
  cat >"$systemd_config_path" <<EOF
[Unit]
Description="HashiCorp Consul"
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=$config_path

[Service]
Type=notify
User=$consul_user
Group=$consul_user
ExecStart=$consul_bin_dir/consul agent -config-dir $consul_config_dir -data-dir $consul_data_dir
ExecReload=$consul_bin_dir/consul reload
ExecStop=$consul_bin_dir/consul leave
KillMode=process
Restart=on-failure
TimeoutSec=300s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

function start_consul {
  log_info "Reloading systemd and starting Consul"
  sudo systemctl daemon-reload
  sudo systemctl enable consul.service
  sudo systemctl restart consul.service
}

function bootstrap {
  local -r consul_token="$1"
  local instance_ip_address
  instance_ip_address=$(get_instance_ip_address)

  while true; do
    consul_leader_addr=$(curl http://localhost:8500/v1/status/leader 2>/dev/null || true)
    if [[ "$consul_leader_addr" == "\"$instance_ip_address:8300\"" ]]; then
      log_info "Bootstrapping Consul ACL"
      echo "${consul_token}" >/tmp/consul.token
      consul acl bootstrap /tmp/consul.token
      rm /tmp/consul.token
      break
    fi
    if [[ -n "$consul_leader_addr" && "$consul_leader_addr" != "\"\"" ]]; then
      log_info "Consul already bootstrapped"
      break
    fi
    log_info "Waiting for Consul to start"
    sleep 1
  done
}

function setup_dns_resolving {
  local consul_token="$1"
  local dns_request_token="$2"

  until consul info -token="${consul_token}" >/dev/null 2>&1; do
    log_info "Waiting for Consul to start"
    sleep 1
  done

  if (($(consul acl policy read -name="dns-request-policy" -token="${consul_token}" -format=json 2>/dev/null | jq '.ID' | wc -l) > 0)); then
    log_info "DNS Request Policy already exists"
  else
    cat <<EOF >/tmp/dns-request-policy.hcl
node_prefix "" { policy = "read" }
service_prefix "" { policy = "read" }
EOF
    cat <<EOF >/tmp/register-service-policy.hcl
service_prefix "" { policy = "write" }
EOF
    consul acl policy create -name "dns-request-policy" -rules @/tmp/dns-request-policy.hcl -token="${consul_token}"
    consul acl policy create -name "register-service-policy" -rules @/tmp/register-service-policy.hcl -token="${consul_token}"
    consul acl token create -secret "${dns_request_token}" -description "Client Token" -policy-name "dns-request-policy" -policy-name "register-service-policy" -token="${consul_token}"
    rm -f /tmp/dns-request-policy.hcl /tmp/register-service-policy.hcl
  fi

  consul acl set-agent-token -token="${consul_token}" default "${dns_request_token}"
  log_info "Client token set"
}

function get_owner_of_path {
  ls -ld "$1" | awk '{print $3}'
}

function run {
  local server="false"
  local client="false"
  local config_dir=""
  local data_dir=""
  local bin_dir=""
  local user=""
  local server_scale_set_name=""
  local datacenter=""
  local enable_gossip_encryption="false"
  local gossip_encryption_key=""
  local consul_token=""
  local dns_request_token=""
  local recursors=()

  while [[ $# -gt 0 ]]; do
    local key="$1"
    case "$key" in
    --server) server="true" ;;
    --client) client="true" ;;
    --consul-token)
      assert_not_empty "$key" "$2"
      consul_token="$2"
      shift
      ;;
    --server-scale-set-name)
      assert_not_empty "$key" "$2"
      server_scale_set_name="$2"
      shift
      ;;
    --datacenter)
      assert_not_empty "$key" "$2"
      datacenter="$2"
      shift
      ;;
    --config-dir)
      assert_not_empty "$key" "$2"
      config_dir="$2"
      shift
      ;;
    --data-dir)
      assert_not_empty "$key" "$2"
      data_dir="$2"
      shift
      ;;
    --bin-dir)
      assert_not_empty "$key" "$2"
      bin_dir="$2"
      shift
      ;;
    --user)
      assert_not_empty "$key" "$2"
      user="$2"
      shift
      ;;
    --enable-gossip-encryption) enable_gossip_encryption="true" ;;
    --gossip-encryption-key)
      assert_not_empty "$key" "$2"
      gossip_encryption_key="$2"
      shift
      ;;
    --dns-request-token)
      assert_not_empty "$key" "$2"
      dns_request_token="$2"
      shift
      ;;
    --recursor)
      assert_not_empty "$key" "$2"
      recursors+=("$2")
      shift
      ;;
    *)
      log_error "Unrecognized argument: $key"
      exit 1
      ;;
    esac
    shift
  done

  if [[ ("$server" == "true" && "$client" == "true") || ("$server" == "false" && "$client" == "false") ]]; then
    log_error "Exactly one of --server or --client must be set."
    exit 1
  fi

  [[ -z "$config_dir" ]] && config_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)
  [[ -z "$data_dir" ]] && data_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../data" && pwd)
  [[ -z "$bin_dir" ]] && bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)
  [[ -z "$user" ]] && user=$(get_owner_of_path "$config_dir")
  [[ -z "$datacenter" ]] && datacenter=$(get_instance_location)

  generate_consul_config "$server" "$consul_token" "$config_dir" "$user" \
    "$server_scale_set_name" "$datacenter" \
    "$enable_gossip_encryption" "$gossip_encryption_key" "${recursors[@]}"

  generate_systemd_config "$SYSTEMD_CONFIG_PATH" "$config_dir" "$data_dir" "$bin_dir" "$user"
  start_consul

  if [[ "$client" == "true" ]]; then
    setup_dns_resolving "$consul_token" "$dns_request_token"
  fi
  if [[ "$server" == "true" ]]; then
    bootstrap "$consul_token"
  fi
}

run "$@"
