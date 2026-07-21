#!/bin/bash
# Configure and run Nomad on an Azure VMSS instance. Azure port of the
# provider-aws run-nomad.sh: instance facts come from Azure IMDS.

set -e
set -x

readonly NOMAD_CONFIG_FILE="default.hcl"
readonly SUPERVISOR_CONFIG_PATH="/etc/supervisor/conf.d/run-nomad.conf"

readonly IMDS_URL="http://169.254.169.254/metadata/instance?api-version=2021-02-01"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"

function log {
  echo >&2 -e "$(date +"%Y-%m-%d %H:%M:%S") [$1] [$SCRIPT_NAME] $2"
}
function log_info { log "INFO" "$1"; }
function log_error { log "ERROR" "$1"; }

function assert_not_empty {
  if [[ -z "$2" ]]; then
    log_error "The value for '$1' cannot be empty"
    exit 1
  fi
}

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
function get_instance_zone { imds_doc | jq -r '.compute.zone // .compute.location'; }
function get_instance_tag_value {
  local -r key="$1"
  imds_doc | jq -r --arg k "$key" '.compute.tagsList[]? | select(.name == $k) | .value' | head -1
}

function assert_is_installed {
  if [[ ! $(command -v "$1") ]]; then
    log_error "The binary '$1' is required but is not installed."
    exit 1
  fi
}

function generate_nomad_config {
  local -r server="$1"
  local -r client="$2"
  local -r num_servers="$3"
  local -r config_dir="$4"
  local -r user="$5"
  local -r consul_token="$6"
  local -r node_pool="$7"
  local -r node_labels="$8"
  local -r orchestrator_job_version="$9"
  local -r config_path="$config_dir/$NOMAD_CONFIG_FILE"

  local instance_name instance_ip_address instance_zone job_constraint
  instance_name=$(get_instance_name)
  instance_ip_address=$(get_instance_ip_address)
  instance_zone=$(get_instance_zone)
  job_constraint=$(get_instance_tag_value "job-constraint" || true)

  local server_config=""
  if [[ "$server" == "true" ]]; then
    server_config=$(
      cat <<EOF
server {
  enabled = true
  bootstrap_expect = $num_servers
  heartbeat_grace = "1m"

  default_scheduler_config {
    memory_oversubscription_enabled = true
  }
}
EOF
    )
  fi

  local client_config=""
  if [[ "$client" == "true" ]]; then
    client_config=$(
      cat <<EOF
client {
  enabled = true
  node_pool = "$node_pool"
  meta {
    "node_pool" = "$node_pool"
    "node_labels" = "${node_labels:-}"
    "orchestrator_version" = "${orchestrator_job_version:-}"
    ${job_constraint:+"\"job_constraint\"" = "\"$job_constraint\""}
  }
  max_kill_timeout = "24h"
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}
EOF
    )
  fi

  log_info "Creating Nomad config file in $config_path"
  cat >"$config_path" <<EOF
datacenter = "$instance_zone"
name       = "$instance_name"
region     = "$(get_instance_location)"
bind_addr  = "0.0.0.0"

advertise {
  http = "$instance_ip_address"
  rpc  = "$instance_ip_address"
  serf = "$instance_ip_address"
}

leave_on_interrupt = true
leave_on_terminate = true

$client_config

$server_config

plugin_dir = "/opt/nomad/plugins"

plugin "docker" {
  config {
    volumes {
      enabled = true
    }
    # ACR auth via the docker-credential-acr-env helper (Managed Identity → ACR
    # token). Nomad's `auth.config` only honours STATIC `auths` from a docker
    # config.json and does NOT invoke credential helpers, so pointing it at a
    # credHelpers file yields anonymous pulls → 401 on private ACR images. Use
    # `auth.helper`, which makes Nomad run `docker-credential-acr-env` for every
    # image. (GCP uses static `auths` with a long-lived service-account key; ACR
    # has no equivalent long-lived static password, so the helper is preferred.)
    auth {
      helper = "acr-env"
    }
  }
}

log_level = "DEBUG"
log_json = true

telemetry {
  collection_interval = "5s"
  disable_hostname = true
  prometheus_metrics = true
  publish_allocation_metrics = true
  publish_node_metrics = true
}

acl {
  enabled = true
}

limits {
  http_max_conns_per_client = 80
  rpc_max_conns_per_client = 80
}

consul {
  address = "127.0.0.1:8500"
  allow_unauthenticated = false
  token = "$consul_token"
}
EOF
  chown "$user:$user" "$config_path"
}

function generate_supervisor_config {
  local -r supervisor_config_path="$1"
  local -r nomad_config_dir="$2"
  local -r nomad_data_dir="$3"
  local -r nomad_bin_dir="$4"
  local -r nomad_log_dir="$5"
  local nomad_user="$6"
  local -r use_sudo="$7"

  if [[ "$use_sudo" == "true" ]]; then
    nomad_user="root"
  fi

  log_info "Creating Supervisor config in $supervisor_config_path"
  cat >"$supervisor_config_path" <<EOF
[program:nomad]
command=$nomad_bin_dir/nomad agent -config $nomad_config_dir -data-dir $nomad_data_dir
stdout_logfile=$nomad_log_dir/nomad-stdout.log
stderr_logfile=$nomad_log_dir/nomad-error.log
numprocs=1
autostart=true
autorestart=true
stopsignal=INT
minfds=65536
user=$nomad_user
EOF
}

function start_nomad {
  log_info "Reloading Supervisor and starting Nomad"
  supervisorctl reread
  supervisorctl update
}

function bootstrap {
  while test -z "$(curl -s http://127.0.0.1:4646/v1/agent/health)"; do
    log_info "Nomad not yet started. Waiting."
    sleep 1
  done
  local -r nomad_token="$1"
  log_info "Bootstrapping Nomad ACL"
  echo "$nomad_token" >"/tmp/nomad.token"
  nomad acl bootstrap /tmp/nomad.token
  rm "/tmp/nomad.token"
}

function create_node_pools {
  local -r nomad_token="$1"
  log_info "Creating node pools"
  cat >"$config_dir/api_node_pool.hcl" <<EOF
node_pool "api" {
  description = "Nodes for api."
}
EOF
  nomad node pool apply -token "$nomad_token" "$config_dir/api_node_pool.hcl"
  cat >"$config_dir/build_node_pool.hcl" <<EOF
node_pool "build" {
  description = "Nodes for template builds."
}
EOF
  nomad node pool apply -token "$nomad_token" "$config_dir/build_node_pool.hcl"
}

function get_owner_of_path {
  ls -ld "$1" | awk '{print $3}'
}

function run {
  local server="false"
  local client="false"
  local num_servers=""
  local nomad_token=""
  local consul_token=""
  local node_pool=""
  local node_labels=""
  local orchestrator_job_version=""
  local use_sudo=""

  while [[ $# -gt 0 ]]; do
    local key="$1"
    case "$key" in
    --server) server="true" ;;
    --client) client="true" ;;
    --num-servers)
      num_servers="$2"
      shift
      ;;
    --nomad-token)
      assert_not_empty "$key" "$2"
      nomad_token="$2"
      shift
      ;;
    --consul-token)
      assert_not_empty "$key" "$2"
      consul_token="$2"
      shift
      ;;
    --node-pool)
      node_pool="$2"
      shift
      ;;
    --node-labels)
      node_labels="$2"
      shift
      ;;
    --orchestrator-job-version)
      orchestrator_job_version="$2"
      shift
      ;;
    --use-sudo) use_sudo="true" ;;
    *)
      log_error "Unrecognized argument: $key"
      exit 1
      ;;
    esac
    shift
  done

  if [[ "$server" == "true" ]]; then
    assert_not_empty "--num-servers" "$num_servers"
  fi
  if [[ "$server" == "false" && "$client" == "false" ]]; then
    log_error "At least one of --server or --client must be set"
    exit 1
  fi
  if [[ -z "$use_sudo" ]]; then
    if [[ "$client" == "true" ]]; then use_sudo="true"; else use_sudo="false"; fi
  fi

  assert_is_installed "supervisorctl"
  assert_is_installed "curl"
  assert_is_installed "jq"

  config_dir=$(cd "$SCRIPT_DIR/../config" && pwd)
  data_dir=$(cd "$SCRIPT_DIR/../data" && pwd)
  bin_dir=$(cd "$SCRIPT_DIR/../bin" && pwd)
  log_dir=$(cd "$SCRIPT_DIR/../log" && pwd)
  user=$(get_owner_of_path "$config_dir")

  generate_nomad_config "$server" "$client" "$num_servers" "$config_dir" "$user" "$consul_token" "$node_pool" "$node_labels" "$orchestrator_job_version"
  generate_supervisor_config "$SUPERVISOR_CONFIG_PATH" "$config_dir" "$data_dir" "$bin_dir" "$log_dir" "$user" "$use_sudo"
  start_nomad

  if [[ "$server" == "true" ]]; then
    bootstrap "$nomad_token"
    create_node_pools "$nomad_token"
  fi
}

run "$@"
