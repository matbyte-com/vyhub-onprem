#!/usr/bin/env bash
#
# vyhub-onprem interactive setup.
#
# Provisions a Hetzner Cloud VM with Docker + the vyhub-onprem stack via
# OpenTofu, drives the post-deploy DNS / Let's Encrypt steps, and offers
# a few convenience subcommands for day-2 operations.
#
# Usage:
#   ./setup.sh              # full interactive flow (default)
#   ./setup.sh apply        # re-run `tofu apply` with the saved inputs
#   ./setup.sh outputs      # print server IPs and management hints
#   ./setup.sh ssh          # ssh into the provisioned server as root
#   ./setup.sh wait         # block until cloud-init finishes
#   ./setup.sh certbot      # request/replace Let's Encrypt cert
#   ./setup.sh redeploy     # destroy and reprovision the server (requires typed confirmation)
#   ./setup.sh destroy      # tear down the Hetzner resources
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOFU_DIR="$SCRIPT_DIR/tofu"
TFVARS_FILE="$TOFU_DIR/terraform.tfvars.json"

VYHUB_SUPPORT_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJXoL+aYkM3veLoFitbjhjvC00spglkOKQeaOAdT8p7d vyhub-support"

# Keep in sync with setup/install.sh REQUIRED_VYHUB_KEYS.
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
  # $1 = path, e.g. /locations
  curl -fsSL -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1$1"
}

# ---------- interactive sections ----------------------------------------------

intro() {
  section "vyhub-onprem setup"
  cat <<'EOF'
This script provisions a Hetzner Cloud VM (Debian 13 + Docker), clones the
vyhub-onprem repo onto it, and brings the stack up. It will guide you
through the few manual steps along the way.

You will need:
  1. A Hetzner Cloud account                  https://accounts.hetzner.com/signUp
  2. A Hetzner Cloud project                  https://console.hetzner.cloud/projects
  3. A read+write API token in that project   Project -> Security -> API Tokens
  4. The VyHub instance env vars              from https://www.vyhub.net
  5. An SSH public key on this machine        (e.g. ~/.ssh/id_ed25519.pub)

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

ask_registry_login() {
  section "Container registry"
  cat <<'EOF'
Paste the docker login command from the vyhub.net setup page, e.g.:

  docker login registry.matbyte.com -u 'robot$vyhub+onprem-1234' -p 'TOKEN'

EOF
  local cmd
  read -r -p "> " cmd

  # Parse: docker login <url> [-u <user>] [-p <pass>]
  # awk strips surrounding single/double quotes from each token.
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

  # Parse KEY="value" / KEY=value lines into a JSON object via jq.
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
    --arg reg_url "$REGISTRY_URL" \
    --arg reg_user "$REGISTRY_USER" \
    --arg reg_pass "$REGISTRY_PASS" \
    '{
      hcloud_token:      $token,
      location:          $location,
      server_type:       $server_type,
      ssh_public_keys:   $ssh_keys,
      vyhub_env:         $vyhub_env,
      enable_backups:    $backups,
      registry_url:      $reg_url,
      registry_user:     $reg_user,
      registry_password: $reg_pass
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

wait_for_cloud_init() {
  section "Waiting for cloud-init"
  local ipv4
  ipv4="$(tofu_output ipv4_address)"
  info "polling root@$ipv4 for /var/lib/vyhub-onprem-ready (this typically takes 3-6 minutes)"
  local attempt=0 max_attempts=120
  while [ $attempt -lt $max_attempts ]; do
    if ssh_to_server "test -f /var/lib/vyhub-onprem-ready" >/dev/null 2>&1; then
      ok "cloud-init finished"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 10
    printf '.'
  done
  printf '\n'
  die "timed out waiting for cloud-init; ssh in and check /var/log/cloud-init-output.log"
}

print_dns_instructions() {
  section "DNS"
  local ipv4 ipv6 frontend host
  ipv4="$(tofu_output ipv4_address)"
  ipv6="$(tofu_output ipv6_address)"
  frontend="$(jq -r '.vyhub_env.VYHUB_FRONTEND_URL' "$TFVARS_FILE")"
  host="$(printf '%s' "$frontend" | sed -E 's#^https?://##; s#/.*$##')"

  cat <<EOF
Create the following DNS records for ${C_BOLD}$host${C_RST}:

  A     $host.   ->  $ipv4
  AAAA  $host.   ->  $ipv6

Once the records propagate, $frontend will resolve to your server.
EOF
}

# ---------- letsencrypt --------------------------------------------------------

run_certbot() {
  section "Let's Encrypt certificate"
  local frontend host email ipv4 resolved
  frontend="$(jq -r '.vyhub_env.VYHUB_FRONTEND_URL' "$TFVARS_FILE")"
  host="$(printf '%s' "$frontend" | sed -E 's#^https?://##; s#/.*$##')"
  ipv4="$(tofu_output ipv4_address)"

  say "Frontend URL: $frontend"
  say "Domain     : $host"
  say "Server IPv4: $ipv4"

  if command -v dig >/dev/null 2>&1; then
    resolved="$(dig +short A "$host" | tail -n1)"
    if [ -n "$resolved" ] && [ "$resolved" != "$ipv4" ]; then
      warn "DNS for $host currently resolves to $resolved (expected $ipv4)"
      prompt_yes_no "Continue anyway?" n || return 0
    fi
  fi

  email="$(prompt "E-Mail address for Let's Encrypt expiry notices")"
  [ -n "$email" ] || die "email is required"

  info "running certbot on the server"
  ssh_to_server "bash /opt/vyhub-onprem/setup/install.sh certbot --domain '$host' --email '$email'"

  ok "Let's Encrypt certificate installed; auto-renewal handled by certbot.timer"
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
  cat <<EOF

Management cheatsheet:
  ssh root@$(tofu_output ipv4_address)
  $0 ssh           # ssh as root
  $0 wait          # wait for cloud-init
  $0 certbot       # request/replace Let's Encrypt cert
  $0 redeploy      # nuke + reprovision (requires typing the server name)
  $0 destroy       # tear down

Application logs (on the server):
  cd /opt/vyhub-onprem && docker compose logs -f
EOF
}

cmd_ssh() {
  ssh_to_server "$@"
}

cmd_wait() {
  wait_for_cloud_init
}

cmd_certbot() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; run \`$0\` first"
  run_certbot
}

cmd_destroy() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; nothing to destroy"
  warn "This will permanently delete the Hetzner server, firewall and SSH keys created by this setup."
  prompt_yes_no "Proceed with destroy?" n || die "aborted"
  ( cd "$TOFU_DIR" && tofu destroy -auto-approve )
  rm -f "$SCRIPT_DIR/.known_hosts"
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

  ( cd "$TOFU_DIR" && tofu destroy -auto-approve )
  rm -f "$SCRIPT_DIR/.known_hosts"
  ( cd "$TOFU_DIR" && tofu apply -auto-approve )

  if prompt_yes_no "Wait for cloud-init to finish?" y; then
    wait_for_cloud_init
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
  ask_registry_login
  ask_env_vars
  ask_backups
  write_tfvars
  run_tofu_apply
  cmd_outputs
  print_dns_instructions

  if prompt_yes_no "Wait for cloud-init to finish now?" y; then
    wait_for_cloud_init
  fi

  if prompt_yes_no "Provision a Let's Encrypt certificate now? (DNS must already point to the server)" y; then
    run_certbot
  else
    say "You can run \`$0 certbot\` later once DNS has propagated."
  fi

  section "Done"
  local frontend
  frontend="$(jq -r '.vyhub_env.VYHUB_FRONTEND_URL' "$TFVARS_FILE")"
  ok "VyHub onprem should now be reachable at $frontend"
}

main() {
  local cmd="${1:-full}"
  case "$cmd" in
    full|"")    cmd_full ;;
    apply)      cmd_apply ;;
    outputs)    cmd_outputs ;;
    ssh)        shift || true; cmd_ssh "$@" ;;
    wait)       cmd_wait ;;
    certbot)    cmd_certbot ;;
    redeploy)   cmd_redeploy ;;
    destroy)    cmd_destroy ;;
    -h|--help|help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)          die "unknown subcommand: $cmd (try --help)" ;;
  esac
}

main "$@"
