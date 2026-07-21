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
    # ACR auth. Nomad's docker driver only reads STATIC auths from a docker
    # config.json; it does NOT invoke credential helpers (credHelpers/helper are
    # ignored), so an anonymous pull 401s on private ACR images. generate_docker_auth
    # (below) mints a token from the MSI-backed acr-env helper and writes it as a
    # static auth to the path below; a systemd timer refreshes it before the ~3h
    # token expiry. Non-ACR nodes get an empty config here (harmless).
    # NOTE: keep this comment free of backticks/dollar-parens: this heredoc is
    # unquoted, so the shell would evaluate them (a backticked command name once
    # dumped its --help output straight into this HCL and broke Nomad startup).
    auth {
      config = "/root/docker/config.json"
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

# Generate static ACR docker auth for Nomad's docker driver.
#
# Nomad's docker driver only reads STATIC `auths` from a docker config.json; it
# does NOT invoke credential helpers. Azure has no long-lived static registry
# password like GCP's service-account key, but the MSI-backed
# docker-credential-acr-env helper mints ~3h ACR tokens. So we run the helper
# once to fetch a token, write it as a static auth, and install a systemd timer
# to refresh it before expiry. Fully reproducible (no manual node patching).
#
# $1: ACR login server (e.g. myreg.azurecr.io). Empty => write an empty config
#     (control-server and other non-pulling nodes), so the driver's auth.config
#     path always exists.
function generate_docker_auth {
  local -r acr_login_server="$1"
  local -r refresh_script="/opt/e2b/refresh-acr-auth.sh"

  mkdir -p /root/docker /opt/e2b

  if [[ -z "$acr_login_server" ]]; then
    log_info "No ACR login server given; writing empty docker auth config"
    echo '{}' >/root/docker/config.json
    chmod 600 /root/docker/config.json
    return
  fi

  log_info "Installing ACR docker-auth refresh script + systemd timer for $acr_login_server"

  # Quoted heredoc: the script's own $vars stay literal (evaluated at runtime,
  # not now). The ACR server is injected via a placeholder to avoid unquoting.
  cat >"$refresh_script" <<'REFRESH'
#!/usr/bin/env bash
# Mint a fresh ACR token via the MSI-backed helper and write it as a STATIC
# docker auth (Nomad's docker driver only honours static auths). Auto-refreshed
# by acr-auth-refresh.timer before the ~3h token expiry.
set -euo pipefail
ACR="__ACR_LOGIN_SERVER__"
cred=$(echo "$ACR" | /usr/local/bin/docker-credential-acr-env get)
token=$(echo "$cred" | sed -n 's/.*"Secret":"\([^"]*\)".*/\1/p')
[ -n "$token" ] || { echo "ACR token empty (helper output: $cred)" >&2; exit 1; }
auth=$(printf '00000000-0000-0000-0000-000000000000:%s' "$token" | base64 -w0)
mkdir -p /root/docker
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$ACR" "$auth" >/root/docker/config.json
chmod 600 /root/docker/config.json
REFRESH
  sed -i "s|__ACR_LOGIN_SERVER__|${acr_login_server}|g" "$refresh_script"
  chmod +x "$refresh_script"

  # Initial generation must succeed before Nomad pulls any ACR image.
  "$refresh_script"

  cat >/etc/systemd/system/acr-auth-refresh.service <<'UNIT'
[Unit]
Description=Refresh static ACR docker auth for Nomad
[Service]
Type=oneshot
ExecStart=/opt/e2b/refresh-acr-auth.sh
UNIT

  cat >/etc/systemd/system/acr-auth-refresh.timer <<'UNIT'
[Unit]
Description=Periodically refresh static ACR docker auth (token lives ~3h)
[Timer]
OnBootSec=10min
OnUnitActiveSec=2h
Persistent=true
[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now acr-auth-refresh.timer
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
  local acr_login_server=""

  while [[ $# -gt 0 ]]; do
    local key="$1"
    case "$key" in
    --server) server="true" ;;
    --client) client="true" ;;
    --acr-login-server)
      acr_login_server="$2"
      shift
      ;;
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
  generate_docker_auth "$acr_login_server"
  start_nomad

  if [[ "$server" == "true" ]]; then
    bootstrap "$nomad_token"
    create_node_pools "$nomad_token"
  fi
}

run "$@"
