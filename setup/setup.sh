#!/usr/bin/env bash
#
# vyhub-onprem interactive setup (Coolify edition).
#
# Provisions a Hetzner Cloud VM, installs Coolify, and uses Coolify's API to
# deploy the vyhub-onprem Docker Compose stack end-to-end. Traefik (managed
# by Coolify) terminates HTTPS via Let's Encrypt for VyHub. The Coolify admin
# UI is not exposed publicly; use `./setup.sh tunnel` to reach it over SSH.
#
# Usage:
#   ./setup.sh              # full interactive flow (default)
#   ./setup.sh apply        # re-run `tofu apply` with the saved inputs
#   ./setup.sh outputs      # print server IPs and management hints
#   ./setup.sh ssh          # ssh into the provisioned server as root
#   ./setup.sh tunnel [PORT]# SSH port-forward Coolify to localhost:PORT (default 8000)
#   ./setup.sh wait         # block until the bootstrap finishes
#   ./setup.sh credentials  # reprint Coolify admin credentials
#   ./setup.sh logs         # tail the bootstrap log on the server
#   ./setup.sh redeploy     # destroy and reprovision the server (requires typed confirmation)
#   ./setup.sh destroy      # tear down the Hetzner resources
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOFU_DIR="$SCRIPT_DIR/tofu"
TFVARS_FILE="$TOFU_DIR/terraform.tfvars.json"
ENV_BLOCK_FILE="$SCRIPT_DIR/.vyhub.env.cache"

VYHUB_SUPPORT_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJXoL+aYkM3veLoFitbjhjvC00spglkOKQeaOAdT8p7d vyhub-support"

REQUIRED_VYHUB_KEYS=(
  VYHUB_BASE_URL
  VYHUB_FRONTEND_URL
  VYHUB_BACKEND_URL
  VYHUB_INSTANCE_ID
  VYHUB_INSTANCE_UID
  VYHUB_SECRET
  VYHUB_AUTH_CENTRAL_CLIENT_ID
  VYHUB_AUTH_CENTRAL_CLIENT_SECRET
)

# ---------- pretty printing ----------------------------------------------------

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi

say()    { printf '%s\n' "$*"; }
info()   { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()     { printf '%s ✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()   { printf '%s !%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()    { printf '%s ✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
section(){ printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RST"; }

# ---------- prerequisites ------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

check_prereqs() {
  require_cmd tofu
  require_cmd ssh
  require_cmd ssh-keygen
  require_cmd curl
  require_cmd jq
  require_cmd openssl
}

# ---------- helpers ------------------------------------------------------------

prompt() {
  local message="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$message [$default]: " reply || true
    printf '%s' "${reply:-$default}"
  else
    read -r -p "$message: " reply || true
    printf '%s' "$reply"
  fi
}

prompt_secret() {
  local message="$1" reply
  read -r -s -p "$message: " reply || true
  printf '\n' >&2
  printf '%s' "$reply"
}

prompt_yes_no() {
  local message="$1" default="${2:-n}" reply
  local hint="[y/N]"
  [ "$default" = "y" ] && hint="[Y/n]"
  read -r -p "$message $hint: " reply || true
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

hcloud_api() {
  curl -fsSL -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1$1"
}

# Load HCLOUD_TOKEN from the saved tfvars (for destroy/redeploy subcommands
# where the user hasn't gone through the interactive token prompt).
load_hcloud_token() {
  HCLOUD_TOKEN="$(jq -r '.hcloud_token // empty' "$TFVARS_FILE")"
  [ -n "$HCLOUD_TOKEN" ] || die "hcloud_token not found in $TFVARS_FILE"
}

# Delete every Hetzner resource carrying our managed-by label, using the
# Hetzner API directly. This is the reliable path: Tofu state may be stale or
# missing, but the label is always on the real resources.
hcloud_purge() {
  local base="https://api.hetzner.cloud/v1"
  local auth_header="Authorization: Bearer $HCLOUD_TOKEN"
  # Filter by label in jq rather than via label_selector URL param — the
  # label_selector query parameter is not supported on all resource types
  # (notably ssh_keys), so fetching all and filtering locally is more reliable.
  local jq_filter='[.[] | select(.labels["managed-by"] == "vyhub-onprem-setup")] | .[].id'

  # --- servers first; firewalls cannot be deleted while still attached --------
  local server_ids
  server_ids=$(hcloud_api "/servers?per_page=100" | jq -r ".servers | $jq_filter")
  for id in $server_ids; do
    info "  deleting server $id"
    curl -X DELETE -fsS -H "$auth_header" "$base/servers/$id" >/dev/null || true
  done

  if [ -n "$server_ids" ]; then
    info "waiting for server deletion to complete..."
    local i count
    for i in $(seq 1 30); do
      count=$(hcloud_api "/servers?per_page=100" \
        | jq "[.servers[] | select(.labels[\"managed-by\"] == \"vyhub-onprem-setup\")] | length" \
        2>/dev/null || echo 1)
      [ "$count" = "0" ] && break
      sleep 10
    done
  fi

  # --- firewalls --------------------------------------------------------------
  for id in $(hcloud_api "/firewalls?per_page=100" | jq -r ".firewalls | $jq_filter"); do
    info "  deleting firewall $id"
    curl -X DELETE -fsS -H "$auth_header" "$base/firewalls/$id" >/dev/null || true
  done

  # --- SSH keys ---------------------------------------------------------------
  for id in $(hcloud_api "/ssh_keys?per_page=100" | jq -r ".ssh_keys | $jq_filter"); do
    info "  deleting SSH key $id"
    curl -X DELETE -fsS -H "$auth_header" "$base/ssh_keys/$id" >/dev/null || true
  done

  ok "Hetzner resources purged"
}

generate_password() {
  # 32 alphanumeric chars — avoids shell/yaml/sed escaping concerns.
  # Use openssl + bash substring to avoid SIGPIPE on a |head pipeline
  # (which set -o pipefail would surface and abort the script).
  local pw
  pw=$(openssl rand -base64 48 | tr -d '+/=\n')
  printf '%s' "${pw:0:32}"
}

extract_host() {
  printf '%s' "$1" | sed -E 's#^https?://##; s#/.*$##'
}

# ---------- interactive sections ----------------------------------------------

intro() {
  section "vyhub-onprem setup (Coolify)"
  cat <<'EOF'
This script provisions a Hetzner Cloud VM, installs Coolify on it, and uses
Coolify's API to deploy the vyhub-onprem Docker Compose stack. Coolify's
built-in Traefik handles HTTPS via Let's Encrypt for VyHub. The Coolify
admin UI is not publicly exposed; access it with: $0 tunnel

You will need:
  1. A Hetzner Cloud account                  https://accounts.hetzner.com/signUp
  2. A Hetzner Cloud project                  https://console.hetzner.cloud/projects
  3. A read+write API token in that project   Project -> Security -> API Tokens
  4. One domain/hostname you control          (e.g. vyhub.example.com)
  5. The VyHub instance env vars              from https://www.vyhub.net
  6. The vyhub container registry login       from https://www.vyhub.net
  7. An SSH public key on this machine        (e.g. ~/.ssh/id_ed25519.pub)

EOF
  if ! prompt_yes_no "Ready to continue?" y; then
    die "aborted by user"
  fi
}

ask_token() {
  section "Hetzner Cloud API token"
  while :; do
    HCLOUD_TOKEN="$(prompt_secret "Paste your Hetzner Cloud API token")"
    [ -n "$HCLOUD_TOKEN" ] || { warn "token must not be empty"; continue; }
    if hcloud_api /locations >/dev/null 2>&1; then
      ok "token verified"
      break
    fi
    warn "token rejected by Hetzner API, please try again"
  done
}

ask_location() {
  section "Hetzner location"
  info "Available locations:"
  hcloud_api /locations \
    | jq -r '.locations[] | "  \(.name)\t\(.city), \(.country)\t(\(.network_zone))"' \
    | column -t -s $'\t'
  LOCATION="$(prompt "Location" "nbg1")"
}

ask_server_type() {
  section "Server type"
  info "Recommended types (CAX = ARM, CPX = AMD, CX = Intel):"
  hcloud_api /server_types \
    | jq -r '.server_types
              | map(select(.deprecated|not))
              | sort_by(.cores)
              | .[]
              | "  \(.name)\t\(.cores)c/\(.memory)GB/\(.disk)GB\t\(.architecture)"' \
    | column -t -s $'\t' | head -n 30
  say "  ..."
  say "  CAX11 (2c / 4GB / 40GB ARM) is the recommended starter size."
  say "  Note: Coolify itself uses ~500 MB RAM on top of the vyhub-onprem stack."
  SERVER_TYPE="$(prompt "Server type" "cax11")"
}

read_ssh_pubkey_file() {
  local path="$1"
  [ -f "$path" ] || { warn "no such file: $path"; return 1; }
  local content
  content="$(tr -d '\n' < "$path")"
  ssh-keygen -l -f "$path" >/dev/null 2>&1 \
    || { warn "$path is not a valid SSH public key"; return 1; }
  printf '%s' "$content"
}

ask_ssh_keys() {
  section "SSH public keys"
  SSH_KEYS=()

  local default_key=""
  for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$cand" ] && { default_key="$cand"; break; }
  done

  while :; do
    local path key
    path="$(prompt "Path to your SSH public key" "$default_key")"
    if key="$(read_ssh_pubkey_file "$path")"; then
      SSH_KEYS+=("$key")
      ok "added key from $path"
      break
    fi
  done

  if prompt_yes_no "Authorize the vyhub-support SSH key for remote troubleshooting?" n; then
    SSH_KEYS+=("$VYHUB_SUPPORT_KEY")
    ok "vyhub-support key will be authorized"
  fi
}

ask_vyhub_settings() {
  section "VyHub settings"
  VYHUB_FQDN="$(prompt "FQDN for VyHub (HTTPS) e.g. vyhub.example.com")"
  [ -n "$VYHUB_FQDN" ] || die "VyHub FQDN is required"
  say "  Coolify's admin UI is not publicly exposed. Use: $0 tunnel"
  COOLIFY_ADMIN_EMAIL="$(prompt "Admin email (used for Coolify login + Let's Encrypt notices)")"
  [ -n "$COOLIFY_ADMIN_EMAIL" ] || die "admin email is required"
  if [ -f "$TFVARS_FILE" ]; then
    COOLIFY_ADMIN_PASSWORD="$(jq -r '.coolify_admin_password // empty' "$TFVARS_FILE")"
  fi
  if [ -z "$COOLIFY_ADMIN_PASSWORD" ]; then
    COOLIFY_ADMIN_PASSWORD="$(generate_password)"
    ok "generated 32-char admin password (will be shown at the end)"
  else
    ok "using existing admin password from $TFVARS_FILE"
  fi
}

ask_registry_login() {
  section "Container registry"
  cat <<'EOF'
Paste the docker login command from the vyhub.net setup page, e.g.:

  docker login registry.matbyte.com -u 'robot$vyhub+onprem-1234' -p 'TOKEN'

EOF
  local cmd
  read -r -p "> " cmd

  local parsed
  parsed="$(printf '%s\n' "$cmd" | awk '{
    url = ""; u = ""; p = ""
    for (i = 1; i <= NF; i++) {
      tok = $i
      gsub(/^'"'"'|'"'"'$|^"|"$/, "", tok)
      if ($(i) == "-u" && i < NF) { i++; u = $(i); gsub(/^'"'"'|'"'"'$|^"|"$/, "", u) }
      else if ($(i) == "-p" && i < NF) { i++; p = $(i); gsub(/^'"'"'|'"'"'$|^"|"$/, "", p) }
      else if (tok != "docker" && tok != "login" && url == "") url = tok
    }
    print url "\t" u "\t" p
  }')"

  REGISTRY_URL="$(printf '%s' "$parsed" | cut -f1)"
  REGISTRY_USER="$(printf '%s' "$parsed" | cut -f2)"
  REGISTRY_PASS="$(printf '%s' "$parsed" | cut -f3)"

  [ -n "$REGISTRY_URL" ]  || die "could not parse registry URL from command"
  [ -n "$REGISTRY_USER" ] || die "could not parse -u from command"
  [ -n "$REGISTRY_PASS" ] || die "could not parse -p from command"
  ok "registry credentials captured (user: $REGISTRY_USER @ $REGISTRY_URL)"
}

ask_env_vars() {
  section "VyHub instance configuration"
  cat <<'EOF'
Generate the env block at https://www.vyhub.net (Setup dialog) and paste it
below. It looks like:

  VYHUB_BASE_URL="https://example.com/api"
  VYHUB_FRONTEND_URL="https://example.com"
  VYHUB_BACKEND_URL="https://example.com/api/v1"
  VYHUB_INSTANCE_ID="..."
  VYHUB_INSTANCE_UID="..."
  VYHUB_SECRET="..."
  VYHUB_AUTH_CENTRAL_CLIENT_ID="..."
  VYHUB_AUTH_CENTRAL_CLIENT_SECRET="..."

Paste the block, then press Ctrl-D on a new line to finish:
EOF
  local block
  block="$(cat)"
  printf '%s\n' "$block" > "$ENV_BLOCK_FILE"
  chmod 600 "$ENV_BLOCK_FILE"

  ENV_JSON="$(printf '%s\n' "$block" | awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      pos = index(line, "=")
      if (pos == 0) next
      key = substr(line, 1, pos-1)
      val = substr(line, pos+1)
      sub(/[[:space:]]*#.*$/, "", val)
      sub(/[[:space:]]+$/, "", val)
      if (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/) {
        val = substr(val, 2, length(val)-2)
      }
      printf "%s\t%s\n", key, val
    }
  ' | jq -R -s '
      split("\n")
      | map(select(length > 0))
      | map(split("\t"))
      | map({(.[0]): (.[1] // "")})
      | add // {}
    ')"

  local missing=()
  for k in "${REQUIRED_VYHUB_KEYS[@]}"; do
    if [ "$(printf '%s' "$ENV_JSON" | jq -r --arg k "$k" '.[$k] // empty')" = "" ]; then
      missing+=("$k")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "missing required vars: ${missing[*]}"
    die "please re-run and paste a complete env block"
  fi

  local steam_key
  say ""
  say "  A Steam Web API key is needed for Steam login. Get one at:"
  say "  https://steamcommunity.com/dev/apikey"
  steam_key="$(prompt "VYHUB_AUTH_STEAM_KEY (optional, press enter to skip)")"
  if [ -n "$steam_key" ]; then
    ENV_JSON="$(printf '%s' "$ENV_JSON" | jq --arg v "$steam_key" '. + {VYHUB_AUTH_STEAM_KEY: $v}')"
  fi

  ok "captured $(printf '%s' "$ENV_JSON" | jq 'length') env vars"
}

ask_backups() {
  section "Hetzner backups"
  if prompt_yes_no "Enable Hetzner Cloud backups (+20% server cost)?" n; then
    ENABLE_BACKUPS=true
  else
    ENABLE_BACKUPS=false
  fi
}

# ---------- tfvars + tofu ------------------------------------------------------

write_tfvars() {
  local ssh_keys_json
  ssh_keys_json="$(printf '%s\n' "${SSH_KEYS[@]}" | jq -R . | jq -s .)"

  jq -n \
    --arg token "$HCLOUD_TOKEN" \
    --arg location "$LOCATION" \
    --arg server_type "$SERVER_TYPE" \
    --argjson ssh_keys "$ssh_keys_json" \
    --argjson vyhub_env "$ENV_JSON" \
    --argjson backups "$ENABLE_BACKUPS" \
    --arg coolify_admin_email "$COOLIFY_ADMIN_EMAIL" \
    --arg coolify_admin_password "$COOLIFY_ADMIN_PASSWORD" \
    --arg vyhub_fqdn "$VYHUB_FQDN" \
    --arg reg_url "$REGISTRY_URL" \
    --arg reg_user "$REGISTRY_USER" \
    --arg reg_pass "$REGISTRY_PASS" \
    '{
      hcloud_token:           $token,
      location:               $location,
      server_type:            $server_type,
      ssh_public_keys:        $ssh_keys,
      vyhub_env:              $vyhub_env,
      enable_backups:         $backups,
      coolify_admin_email:    $coolify_admin_email,
      coolify_admin_password: $coolify_admin_password,
      vyhub_fqdn:             $vyhub_fqdn,
      registry_url:           $reg_url,
      registry_user:          $reg_user,
      registry_password:      $reg_pass
    }' > "$TFVARS_FILE"
  chmod 600 "$TFVARS_FILE"
  ok "wrote $TFVARS_FILE"
}

run_tofu_apply() {
  section "Provisioning with OpenTofu"
  ( cd "$TOFU_DIR" && tofu init -upgrade )
  ( cd "$TOFU_DIR" && tofu apply -auto-approve )
}

# ---------- post-provision -----------------------------------------------------

tofu_output() {
  ( cd "$TOFU_DIR" && tofu output -raw "$1" )
}

ssh_to_server() {
  local ipv4 ssh_args=("-o" "StrictHostKeyChecking=accept-new" "-o" "UserKnownHostsFile=$SCRIPT_DIR/.known_hosts")
  ipv4="$(tofu_output ipv4_address)"
  ssh "${ssh_args[@]}" "root@$ipv4" "$@"
}

print_dns_instructions() {
  section "DNS"
  local ipv4 ipv6 vyhub_host
  ipv4="$(tofu_output ipv4_address)"
  ipv6="$(tofu_output ipv6_address)"
  vyhub_host="$(jq -r '.vyhub_fqdn' "$TFVARS_FILE")"

  cat <<EOF
Create the following DNS records (TTL 60s is convenient for setup):

  A     $vyhub_host.   ->  $ipv4
  AAAA  $vyhub_host.   ->  $ipv6

Let's Encrypt will only succeed once DNS resolves to this server.
EOF
}

wait_for_coolify() {
  section "Waiting for Coolify bootstrap"
  local ipv4
  ipv4="$(tofu_output ipv4_address)"
  info "polling root@$ipv4 for /var/lib/vyhub-coolify-ready (typically 8-15 minutes)"
  info "tail the live log with: $0 logs"
  local attempt=0 max_attempts=180
  while [ $attempt -lt $max_attempts ]; do
    if ssh_to_server "test -f /var/lib/vyhub-coolify-ready" >/dev/null 2>&1; then
      ok "Coolify bootstrap finished"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 10
    printf '.'
  done
  printf '\n'
  die "timed out waiting for bootstrap; ssh in and check /var/log/vyhub-coolify-bootstrap.log"
}

print_credentials() {
  section "Credentials"
  local vyhub_host pw email ipv4
  vyhub_host="$(jq -r '.vyhub_fqdn' "$TFVARS_FILE")"
  pw="$(jq -r '.coolify_admin_password' "$TFVARS_FILE")"
  email="$(jq -r '.coolify_admin_email' "$TFVARS_FILE")"
  ipv4="$(tofu_output ipv4_address)"

  cat <<EOF
Coolify UI:   ${C_BOLD}http://localhost:8000${C_RST}  (SSH tunnel only — not public)
  Open:       ${C_DIM}$0 tunnel${C_RST}
  Email:      ${C_BOLD}$email${C_RST}
  Password:   ${C_BOLD}$pw${C_RST}

VyHub:        ${C_BOLD}https://$vyhub_host${C_RST}
              (cert issued as soon as DNS for $vyhub_host resolves)

Password also stored in $TFVARS_FILE (chmod 600). Rotate it in Coolify.
EOF
}

# ---------- subcommands --------------------------------------------------------

cmd_apply() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; run \`$0\` first"
  ( cd "$TOFU_DIR" && tofu init -upgrade && tofu apply -auto-approve )
  cmd_outputs
}

cmd_outputs() {
  section "Server"
  ( cd "$TOFU_DIR" && tofu output )
  local ipv4
  ipv4="$(tofu_output ipv4_address)"
  cat <<EOF

Management cheatsheet:
  ssh root@$ipv4
  $0 ssh           # ssh as root
  $0 tunnel        # SSH port-forward Coolify to localhost:8000
  $0 wait          # wait for the bootstrap to finish
  $0 logs          # tail the bootstrap log
  $0 credentials   # reprint Coolify admin credentials
  $0 redeploy      # nuke + reprovision (requires typing the server name)
  $0 destroy       # tear down
EOF
}

cmd_ssh() {
  ssh_to_server "$@"
}

cmd_tunnel() {
  local local_port="${1:-8000}"
  local ipv4
  ipv4="$(tofu_output ipv4_address)"
  info "Forwarding localhost:$local_port -> $ipv4:8000 (Coolify)"
  info "Open http://localhost:$local_port in your browser. Ctrl-C to stop."
  ssh_to_server -N -L "${local_port}:localhost:8000"
}

cmd_wait() {
  wait_for_coolify
}

cmd_credentials() {
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; nothing to print"
  print_credentials
}

cmd_logs() {
  ssh_to_server "tail -F /var/log/vyhub-coolify-bootstrap.log"
}

_do_destroy() {
  # 1. tofu destroy uses the state file's exact resource IDs — the fast path.
  ( cd "$TOFU_DIR" && tofu destroy -auto-approve ) || true
  # 2. hcloud_purge is a safety net for anything that leaked outside state
  #    (e.g. partial previous run, manually created resources with our label).
  hcloud_purge
  rm -f "$TOFU_DIR/terraform.tfstate" "$TOFU_DIR/terraform.tfstate.backup" \
        "$SCRIPT_DIR/.known_hosts"
}

cmd_destroy() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; nothing to destroy"
  warn "This will permanently delete the Hetzner server, firewall and SSH keys."
  prompt_yes_no "Proceed with destroy?" n || die "aborted"
  load_hcloud_token
  _do_destroy
}

cmd_redeploy() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; run \`$0\` first"

  local server_name
  server_name="$(jq -r '.server_name // "vyhub-onprem"' "$TFVARS_FILE")"

  section "Redeploy"
  warn "This will DESTROY the current server (including all data and DB backups"
  warn "stored on it) and provision a fresh one from scratch."
  say ""
  say "  Server: ${C_BOLD}$server_name${C_RST}"
  say ""
  say "Type the server name to confirm: "
  local reply
  read -r reply
  [ "$reply" = "$server_name" ] || die "confirmation did not match — aborted"

  load_hcloud_token
  _do_destroy
  ( cd "$TOFU_DIR" && tofu init -upgrade && tofu apply -auto-approve )

  if prompt_yes_no "Wait for the bootstrap to finish?" y; then
    wait_for_coolify
    print_credentials
  fi

  ok "server redeployed"
  cmd_outputs
}

cmd_full() {
  check_prereqs
  intro
  ask_token
  ask_location
  ask_server_type
  ask_ssh_keys
  ask_vyhub_settings
  ask_registry_login
  ask_env_vars
  ask_backups
  write_tfvars
  run_tofu_apply
  cmd_outputs
  print_dns_instructions

  say ""
  warn "Set the DNS records above NOW. Let's Encrypt will fail until they resolve."
  say ""

  if prompt_yes_no "Wait for the bootstrap (Coolify install + VyHub deploy) to finish?" y; then
    wait_for_coolify
  fi

  print_credentials

  section "Done"
  ok "Setup complete. Log in to Coolify with the credentials above."
}

main() {
  local cmd="${1:-full}"
  case "$cmd" in
    full|"")      cmd_full ;;
    apply)        cmd_apply ;;
    outputs)      cmd_outputs ;;
    ssh)          shift || true; cmd_ssh "$@" ;;
    tunnel)       shift || true; cmd_tunnel "$@" ;;
    wait)         cmd_wait ;;
    credentials)  cmd_credentials ;;
    logs)         cmd_logs ;;
    redeploy)     cmd_redeploy ;;
    destroy)      cmd_destroy ;;
    -h|--help|help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)            die "unknown subcommand: $cmd (try --help)" ;;
  esac
}

main "$@"
