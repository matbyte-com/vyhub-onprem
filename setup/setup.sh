#!/usr/bin/env bash
#
# vyhub-onprem interactive setup.
#
# Provisions a Hetzner Cloud VM running Talos Linux, bootstraps a
# single-node Kubernetes cluster on it, and installs the vyhub Helm chart
# from charts.matbyte.com. Talos and Kubernetes auto-upgrade via Rancher's
# system-upgrade-controller (channels reconciled in-cluster, no cron).
#
# Usage:
#   ./setup.sh              # full interactive flow (default)
#   ./setup.sh apply        # re-run `tofu apply` with the saved inputs
#   ./setup.sh bootstrap    # apply Talos config + bootstrap etcd
#   ./setup.sh platform     # install traefik + cert-manager + Let's Encrypt issuer
#   ./setup.sh install      # helm upgrade --install vyhub
#   ./setup.sh upgrades     # (re)install system-upgrade-controller + plans
#   ./setup.sh firewall     # narrow Hetzner FW to your current public IP(s)
#   ./setup.sh kubeconfig   # write kubeconfig + talosconfig to ./.local
#   ./setup.sh outputs      # print server IPs and management hints
#   ./setup.sh redeploy     # destroy and reprovision the server (requires typed confirmation)
#   ./setup.sh destroy      # tear down the Hetzner resources
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOFU_DIR="$SCRIPT_DIR/tofu"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
TFVARS_FILE="$TOFU_DIR/terraform.tfvars.json"
ENV_BLOCK_FILE="$SCRIPT_DIR/.vyhub.env.cache"
LOCAL_DIR="$SCRIPT_DIR/.local"
KUBECONFIG_FILE="$LOCAL_DIR/kubeconfig"
TALOSCONFIG_FILE="$LOCAL_DIR/talosconfig"
MACHINECONFIG_FILE="$LOCAL_DIR/controlplane.yaml"

# Chart to install. Defaults to the stable `vyhub` chart on
# charts.matbyte.com (published from master via .github/workflows/charts.yml).
# When VYHUB_CHART_REPO is empty, VYHUB_CHART_REF is passed straight to
# helm — useful for local paths (./charts/vyhub or a packaged .tgz).
VYHUB_CHART_REPO="${VYHUB_CHART_REPO-https://charts.matbyte.com}"
VYHUB_CHART_REF="${VYHUB_CHART_REF:-vyhub}"
# Optional explicit chart version (helm --version). Pre-release versions
# (e.g. 1.0.0-setup-k8s) require this flag — `helm` skips them otherwise.
VYHUB_CHART_VERSION="${VYHUB_CHART_VERSION:-}"
SUC_VERSION="v0.16.0"
SUC_URL="https://github.com/rancher/system-upgrade-controller/releases/download/${SUC_VERSION}/system-upgrade-controller.yaml"
SUC_CRD_URL="https://github.com/rancher/system-upgrade-controller/releases/download/${SUC_VERSION}/crd.yaml"

# Platform charts: ingress (Traefik) + cert-manager. Pinned to known-good
# versions; bump deliberately, not on a whim.
TRAEFIK_CHART_VERSION="33.0.0"
CERT_MANAGER_CHART_VERSION="v1.16.2"
METRICS_SERVER_CHART_VERSION="3.12.2"
LETSENCRYPT_ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
LETSENCRYPT_STAGING_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"

# Pinned talosctl image used by both upgrade Plans. Without a tag, SUC would
# append the resolved channel version - which works for the Talos plan but
# fails for the K8s plan (no talosctl:v1.34.x). Bump alongside TALOS_MAX -
# talosctl is strict about client/server skew and refuses to operate on a
# newer Talos minor than the client.
TALOSCTL_IMAGE_TAG="v1.13.2"
# Highest Talos minor version `setup.sh upgrades` is willing to roll the
# cluster onto. The in-cluster resolver CronJob tracks the latest patch
# within this minor (or steps one minor up, clamped here) - this avoids
# surprise minor jumps that would break talosctl client/server skew rules.
TALOS_MAX_MINOR_VERSION="1.13"
# Highest Kubernetes minor version supported by the currently pinned Talos
# release (see https://www.talos.dev/<minor>/introduction/support-matrix/).
# `setup.sh upgrades` computes a target one minor above the cluster's
# current version, clamped to this cap, so re-running `upgrades` walks the
# cluster forward one hop at a time (talosctl rejects multi-minor jumps).
# Bump together with TALOS_MAX_MINOR_VERSION + TALOSCTL_IMAGE_TAG.
KUBERNETES_MAX_MINOR_VERSION="1.35"

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
  require_cmd talosctl
  require_cmd kubectl
  require_cmd helm
  require_cmd curl
  require_cmd jq
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

ensure_local_dir() {
  mkdir -p "$LOCAL_DIR"
  chmod 700 "$LOCAL_DIR"
}

tofu_output() {
  ( cd "$TOFU_DIR" && tofu output -raw "$1" )
}

tofu_output_json() {
  ( cd "$TOFU_DIR" && tofu output -json "$1" )
}

# ---------- interactive sections ----------------------------------------------

intro() {
  section "vyhub-onprem setup"
  cat <<'EOF'
This script provisions a Hetzner Cloud VM running Talos Linux, brings up
a single-node Kubernetes cluster on it, and installs the vyhub Helm chart
from charts.matbyte.com. Talos and Kubernetes auto-update via Rancher's
system-upgrade-controller.

You will need:
  1. A Hetzner Cloud account                  https://accounts.hetzner.com/signUp
  2. A Hetzner Cloud project                  https://console.hetzner.cloud/projects
  3. A read+write API token in that project   Project -> Security -> API Tokens
  4. The VyHub instance env vars              from https://www.vyhub.net
  5. Locally installed: tofu, talosctl, kubectl, helm, jq, curl

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
  info "Talos needs >=2 vCPU / >=2GB RAM for a single-node control plane."
  info "Recommended types (CAX = ARM, CPX = AMD, CX = Intel):"
  hcloud_api /server_types \
    | jq -r '.server_types
              | map(select(.deprecated|not))
              | sort_by(.cores)
              | .[]
              | "  \(.name)\t\(.cores)c/\(.memory)GB/\(.disk)GB\t\(.architecture)"' \
    | column -t -s $'\t' | head -n 30
  say "  ..."
  say "  CAX21 (4c / 8GB / 80GB ARM) is the recommended starter size."
  SERVER_TYPE="$(prompt "Server type" "cax21")"
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

ask_acme_email() {
  section "Let's Encrypt"
  cat <<'EOF'
A Let's Encrypt ClusterIssuer will be created in-cluster (cert-manager)
and the vyhub Ingress will request a cert for VYHUB_FRONTEND_URL's host.

You need an e-mail address for ACME expiry notices.
EOF
  while :; do
    ACME_EMAIL="$(prompt "E-Mail address for Let's Encrypt")"
    [ -n "$ACME_EMAIL" ] || { warn "email is required"; continue; }
    break
  done

  if prompt_yes_no "Use Let's Encrypt staging (untrusted certs, no rate limits)?" n; then
    ACME_SERVER="$LETSENCRYPT_STAGING_SERVER"
  else
    ACME_SERVER="$LETSENCRYPT_ACME_SERVER"
  fi
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
  jq -n \
    --arg token "$HCLOUD_TOKEN" \
    --arg location "$LOCATION" \
    --arg server_type "$SERVER_TYPE" \
    --argjson backups "$ENABLE_BACKUPS" \
    '{
      hcloud_token:      $token,
      location:          $location,
      server_type:       $server_type,
      enable_backups:    $backups
    }' > "$TFVARS_FILE"
  chmod 600 "$TFVARS_FILE"
  ok "wrote $TFVARS_FILE"

  # Stash registry creds + env vars in a sibling file the helm install reads.
  jq -n \
    --arg reg_url "$REGISTRY_URL" \
    --arg reg_user "$REGISTRY_USER" \
    --arg reg_pass "$REGISTRY_PASS" \
    --arg acme_email "$ACME_EMAIL" \
    --arg acme_server "$ACME_SERVER" \
    --argjson vyhub_env "$ENV_JSON" \
    '{
      registry_url:      $reg_url,
      registry_user:     $reg_user,
      registry_password: $reg_pass,
      acme_email:        $acme_email,
      acme_server:       $acme_server,
      vyhub_env:         $vyhub_env
    }' > "$SCRIPT_DIR/.vyhub.install.json"
  chmod 600 "$SCRIPT_DIR/.vyhub.install.json"
}

run_tofu_apply() {
  section "Provisioning with OpenTofu"
  ( cd "$TOFU_DIR" && tofu init -upgrade )
  ( cd "$TOFU_DIR" && tofu apply -auto-approve )
}

# ---------- Talos bootstrap ----------------------------------------------------

write_local_configs() {
  ensure_local_dir
  tofu_output talos_machine_configuration > "$MACHINECONFIG_FILE"
  tofu_output talosconfig                 > "$TALOSCONFIG_FILE"
  chmod 600 "$MACHINECONFIG_FILE" "$TALOSCONFIG_FILE"
  ok "wrote $MACHINECONFIG_FILE"
  ok "wrote $TALOSCONFIG_FILE"
}

wait_for_talos_iso_boot() {
  local ipv4="$1" attempt=0 max_attempts=60
  info "waiting for Talos to come up on $ipv4:50000 (maintenance mode)"
  while [ $attempt -lt $max_attempts ]; do
    if (echo > /dev/tcp/"$ipv4"/50000) >/dev/null 2>&1; then
      ok "Talos API reachable"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 10
    printf '.'
  done
  printf '\n'
  die "timed out waiting for Talos to boot from ISO"
}

apply_machine_config() {
  local ipv4="$1"
  info "applying Talos machine config (--insecure, ISO maintenance mode)"
  talosctl apply-config --insecure \
    --nodes "$ipv4" \
    --file "$MACHINECONFIG_FILE"
  ok "machine config applied; Talos is installing to disk and will reboot"
}

detach_iso_and_wait() {
  local server_id="$1" ipv4="$2"
  info "detaching ISO via Hetzner API so the server boots from the installed disk"
  curl -fsSL -X POST \
    -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1/servers/$server_id/actions/detach_iso" >/dev/null
  ok "ISO detached"

  info "waiting for Talos to come back up after disk-boot"
  local attempt=0 max_attempts=60
  # The apid will briefly disappear during reboot; wait it out.
  sleep 20
  while [ $attempt -lt $max_attempts ]; do
    if talosctl --talosconfig "$TALOSCONFIG_FILE" --nodes "$ipv4" version >/dev/null 2>&1; then
      ok "Talos is running off disk"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 10
    printf '.'
  done
  printf '\n'
  die "timed out waiting for disk-installed Talos to come up"
}

bootstrap_etcd() {
  local ipv4="$1"
  info "bootstrapping etcd"
  # The bootstrap call only needs to succeed once; subsequent calls error.
  if talosctl --talosconfig "$TALOSCONFIG_FILE" --nodes "$ipv4" \
      bootstrap >/dev/null 2>&1; then
    ok "etcd bootstrap requested"
  else
    warn "bootstrap returned non-zero (already bootstrapped?); continuing"
  fi

  info "waiting for cluster to be healthy (this can take 3-5 minutes)"
  talosctl --talosconfig "$TALOSCONFIG_FILE" --nodes "$ipv4" \
    health --wait-timeout=15m
  ok "cluster healthy"
}

fetch_kubeconfig() {
  local ipv4="$1"
  talosctl --talosconfig "$TALOSCONFIG_FILE" --nodes "$ipv4" \
    kubeconfig --force "$KUBECONFIG_FILE"
  chmod 600 "$KUBECONFIG_FILE"
  ok "wrote $KUBECONFIG_FILE"
}

cmd_bootstrap() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; run \`$0\` first"

  HCLOUD_TOKEN="$(jq -r '.hcloud_token' "$TFVARS_FILE")"
  local ipv4 server_id
  ipv4="$(tofu_output ipv4_address)"
  server_id="$(tofu_output server_id)"

  write_local_configs
  wait_for_talos_iso_boot "$ipv4"
  apply_machine_config "$ipv4"
  detach_iso_and_wait "$server_id" "$ipv4"
  bootstrap_etcd "$ipv4"
  fetch_kubeconfig "$ipv4"
}

# ---------- helm install -------------------------------------------------------

kctl() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"
}

hctl() {
  helm --kubeconfig "$KUBECONFIG_FILE" "$@"
}

# Poll kube-apiserver until it returns healthy. Used to ride out SUC-driven
# Talos / Kubernetes upgrades that take the API server down mid-install on
# single-node clusters - without this, any kubectl call during the drain +
# reboot window would fail with "connection refused" and abort the script.
wait_for_apiserver() {
  local timeout="${1:-600}" elapsed=0 step=5
  while [ $elapsed -lt $timeout ]; do
    if kctl --request-timeout=3s get --raw=/livez >/dev/null 2>&1; then
      [ $elapsed -gt 0 ] && ok "kube-apiserver back online after ${elapsed}s"
      return 0
    fi
    [ $elapsed -eq 0 ] && info "waiting for kube-apiserver (may be mid-upgrade)..."
    sleep $step
    elapsed=$((elapsed + step))
  done
  die "kube-apiserver did not become ready within ${timeout}s"
}

# Detect the operator's current outbound public IPs. Returns a JSON array
# of CIDRs ready to splice into tofu's admin_cidrs variable. IPv6 detection
# is best-effort: a network without v6 will silently fall back to v4 only.
detect_admin_cidrs() {
  local v4 v6 out=()
  v4="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  v6="$(curl -fsS6 --max-time 5 https://api6.ipify.org 2>/dev/null || true)"
  [ -n "$v4" ] && out+=("\"${v4}/32\"")
  [ -n "$v6" ] && out+=("\"${v6}/128\"")
  [ ${#out[@]} -gt 0 ] || die "could not detect public IP (api.ipify.org unreachable)"
  printf '[%s]\n' "$(IFS=,; echo "${out[*]}")"
}

# True if a TCP SYN to host:port elicits ANY response (SYN-ACK or RST)
# within 3s. A SYN-ACK means port open, an RST means port closed but host
# reachable - both indicate the firewall is letting us through. Only a
# timeout (rc=124) means we're blocked. Uses bash's /dev/tcp so no nc
# dependency.
tcp_reachable() {
  local host="$1" port="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
  [ $? -ne 124 ]
}

# True when both the Talos and Kubernetes API ports are reachable at the
# TCP layer. This deliberately does NOT care whether the APIs themselves
# respond - that's wait_for_apiserver's job. We only catch the firewall-
# blocked case here so a normal mid-upgrade outage doesn't trigger a
# spurious firewall refresh.
apis_reachable() {
  local ipv4
  ipv4="$(jq -r '.endpoints[0] // empty' "$TALOSCONFIG_FILE" 2>/dev/null)"
  [ -n "$ipv4" ] || ipv4="$(cd "$TOFU_DIR" && tofu output -raw ipv4_address 2>/dev/null || true)"
  [ -n "$ipv4" ] || return 0   # no endpoint to check (pre-bootstrap)
  tcp_reachable "$ipv4" 6443 && tcp_reachable "$ipv4" 50000
}

# Refresh the Hetzner Cloud firewall to allow the operator's current public
# IPs to reach the Talos + Kubernetes APIs. Called manually via
# `setup.sh firewall` and once automatically by ensure_api_access if the
# APIs look blocked.
cmd_firewall() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; run \`$0\` first"
  section "Refreshing Hetzner Cloud firewall to current admin IPs"
  local cidrs; cidrs="$(detect_admin_cidrs)"
  info "admin_cidrs = $cidrs"
  local tmp; tmp="$(mktemp)"
  jq --argjson cidrs "$cidrs" '.admin_cidrs = $cidrs' "$TFVARS_FILE" > "$tmp" \
    && mv "$tmp" "$TFVARS_FILE"
  chmod 600 "$TFVARS_FILE"
  ( cd "$TOFU_DIR" && tofu apply -auto-approve -target=hcloud_firewall.this ) \
    || die "tofu apply failed"
  ok "firewall updated"
}

# Called from subcommands that need API access. Probes both APIs once; if
# they look blocked, refreshes the firewall once (no retry loop) and probes
# again. Stateful via FIREWALL_REFRESH_TRIED so a genuinely down cluster
# still fails fast with a clear message.
FIREWALL_REFRESH_TRIED=0
ensure_api_access() {
  [ "$FIREWALL_REFRESH_TRIED" -eq 1 ] && return 0
  apis_reachable && return 0
  warn "Talos/Kubernetes API unreachable - attempting one-shot firewall refresh"
  FIREWALL_REFRESH_TRIED=1
  cmd_firewall || warn "firewall refresh failed"
  apis_reachable && { ok "APIs reachable after firewall refresh"; return 0; }
  die "APIs still unreachable after firewall refresh - check Hetzner Cloud firewall + node status manually"
}

install_registry_pull_secret() {
  local install_file="$SCRIPT_DIR/.vyhub.install.json"
  [ -f "$install_file" ] || die "missing $install_file (registry creds)"

  local reg_url reg_user reg_pass
  reg_url="$(jq -r '.registry_url' "$install_file")"
  reg_user="$(jq -r '.registry_user' "$install_file")"
  reg_pass="$(jq -r '.registry_password' "$install_file")"

  kctl create namespace vyhub --dry-run=client -o yaml | kctl apply -f -
  kctl -n vyhub create secret docker-registry vyhub-registry \
    --docker-server="$reg_url" \
    --docker-username="$reg_user" \
    --docker-password="$reg_pass" \
    --dry-run=client -o yaml | kctl apply -f -
  ok "registry pull secret installed in namespace vyhub"
}

cmd_install() {
  check_prereqs
  [ -f "$KUBECONFIG_FILE" ] || die "no kubeconfig; run \`$0 bootstrap\` first"
  local install_file="$SCRIPT_DIR/.vyhub.install.json"
  [ -f "$install_file" ] || die "no $install_file; re-run \`$0\` to capture creds + env"

  section "Installing vyhub Helm chart"

  ensure_api_access
  wait_for_apiserver
  install_registry_pull_secret

  # Resolve the public hostname from VYHUB_FRONTEND_URL for the Ingress.
  local frontend_host
  frontend_host="$(jq -r '.vyhub_env.VYHUB_FRONTEND_URL // ""' "$install_file" \
    | sed -E 's#^https?://##; s#/.*$##')"
  [ -n "$frontend_host" ] || die "could not parse host from VYHUB_FRONTEND_URL"

  # Persist a generated postgres password on first run so re-runs are
  # idempotent (changing it would orphan the PVC's existing data dir).
  local pg_pass
  pg_pass="$(jq -r '.postgres_password // ""' "$install_file")"
  if [ -z "$pg_pass" ]; then
    pg_pass="$(openssl rand -hex 24)"
    local tmp; tmp="$(mktemp)"
    jq --arg p "$pg_pass" '.postgres_password = $p' \
      "$install_file" > "$tmp" && mv "$tmp" "$install_file"
    chmod 600 "$install_file"
  fi

  # Build the `vyhub-app-env` secret the chart's README expects (referenced
  # via app.extraEnvVarsSecret). It carries the secret env block from
  # vyhub.net plus an auto-derived VYHUB_DATABASE_URL pointing at the
  # bundled postgres StatefulSet.
  kctl create namespace vyhub --dry-run=client -o yaml | kctl apply -f - >/dev/null
  local db_url="postgresql://vyhub:${pg_pass}@vyhub-postgresql.vyhub.svc.cluster.local:5432/vyhub"
  local env_file; env_file="$(mktemp)"
  trap "rm -f $env_file" RETURN
  jq -r --arg dburl "$db_url" '
    (.vyhub_env + {VYHUB_DATABASE_URL: $dburl})
    | to_entries[]
    | "\(.key)=\(.value)"
  ' "$install_file" > "$env_file"
  kctl -n vyhub create secret generic vyhub-app-env \
    --from-env-file="$env_file" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
  ok "vyhub-app-env secret applied (includes VYHUB_DATABASE_URL)"

  # Build a values file. Non-secret app.config.* fields are inlined; the
  # secret env block is mounted via extraEnvVarsSecret (above).
  local vals="$LOCAL_DIR/values.generated.yaml"
  ensure_local_dir
  jq -r --arg host "$frontend_host" --arg pgpw "$pg_pass" '
    .vyhub_env as $e
    | {
        global: { imagePullSecrets: ["vyhub-registry"] },
        app: {
          extraEnvVarsSecret: "vyhub-app-env",
          config: {
            baseUrl:     ($e.VYHUB_BASE_URL     // ""),
            frontendUrl: ($e.VYHUB_FRONTEND_URL // ""),
            backendUrl:  ($e.VYHUB_BACKEND_URL  // ""),
            instanceId:  ($e.VYHUB_INSTANCE_ID  // ""),
            instanceUid: ($e.VYHUB_INSTANCE_UID // "")
          }
        },
        ingress: {
          enabled: true,
          ingressClassName: "traefik",
          hostname: $host,
          tls: true,
          annotations: {
            "cert-manager.io/cluster-issuer": "letsencrypt"
          }
        },
        postgresql: {
          enabled: true,
          auth: { password: $pgpw }
        }
      }
  ' "$install_file" > "$vals"

  local extra_args=()
  [ -n "$VYHUB_CHART_REPO" ]    && extra_args+=(--repo "$VYHUB_CHART_REPO")
  [ -n "$VYHUB_CHART_VERSION" ] && extra_args+=(--version "$VYHUB_CHART_VERSION")

  info "helm upgrade --install vyhub $VYHUB_CHART_REF${VYHUB_CHART_REPO:+ --repo $VYHUB_CHART_REPO}${VYHUB_CHART_VERSION:+ --version $VYHUB_CHART_VERSION} -n vyhub -f $vals"
  hctl upgrade --install vyhub "$VYHUB_CHART_REF" \
    "${extra_args[@]}" \
    --namespace vyhub \
    --create-namespace \
    --values "$vals" \
    --wait --timeout 15m

  ok "vyhub chart installed; pods coming up:"
  kctl -n vyhub get pods
}

# ---------- platform: traefik + cert-manager + Let's Encrypt -----------------

install_traefik() {
  info "installing Traefik ingress controller"
  hctl repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  hctl repo update traefik >/dev/null

  # Talos enforces PodSecurity "baseline" on every namespace by default.
  # hostNetwork + hostPort require the "privileged" profile, so create the
  # namespace ahead of time and label it explicitly.
  kctl create namespace traefik --dry-run=client -o yaml | kctl apply -f - >/dev/null
  kctl label --overwrite namespace traefik \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged >/dev/null

  # Traefik exposes web/websecure as a Service of type LoadBalancer. On a
  # single-node Hetzner setup without a cloud-LB we run it as hostNetwork so
  # ports 80/443 on the node's public IP go straight to traefik.
  hctl upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --create-namespace \
    --version "$TRAEFIK_CHART_VERSION" \
    --set "deployment.kind=DaemonSet" \
    --set "hostNetwork=true" \
    --set "service.enabled=false" \
    --set "ports.web.port=80" \
    --set "ports.web.hostPort=80" \
    --set "ports.web.redirectTo.port=websecure" \
    --set "ports.websecure.port=443" \
    --set "ports.websecure.hostPort=443" \
    --set "ingressClass.enabled=true" \
    --set "ingressClass.isDefaultClass=true" \
    --set "ingressClass.name=traefik" \
    --set "updateStrategy.rollingUpdate.maxUnavailable=1" \
    --set "updateStrategy.rollingUpdate.maxSurge=0" \
    --set "securityContext.capabilities.drop={ALL}" \
    --set "securityContext.capabilities.add={NET_BIND_SERVICE}" \
    --set "securityContext.runAsNonRoot=false" \
    --set "securityContext.runAsUser=0" \
    --set "securityContext.runAsGroup=0" \
    --set "podSecurityContext.runAsNonRoot=false" \
    --set "podSecurityContext.runAsUser=0" \
    --set "podSecurityContext.runAsGroup=0" \
    --wait --timeout 5m
  ok "Traefik installed (ingressClass=traefik, hostNetwork on ports 80/443)"
}

install_cert_manager() {
  info "installing cert-manager"
  hctl repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  hctl repo update jetstack >/dev/null

  hctl upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_CHART_VERSION" \
    --set "crds.enabled=true" \
    --wait --timeout 5m
  ok "cert-manager installed"
}

install_letsencrypt_issuer() {
  local install_file="$SCRIPT_DIR/.vyhub.install.json"
  [ -f "$install_file" ] || die "missing $install_file (ACME email)"

  local acme_email acme_server
  acme_email="$(jq -r '.acme_email  // ""' "$install_file")"
  acme_server="$(jq -r '.acme_server // ""' "$install_file")"
  [ -n "$acme_email" ]  || die "no acme_email in $install_file; re-run \`$0\` to capture it"
  [ -n "$acme_server" ] || acme_server="$LETSENCRYPT_ACME_SERVER"

  info "applying ClusterIssuer letsencrypt (acme: $acme_server)"

  # cert-manager's webhook can take a few seconds after the deploy goes
  # ready to actually accept CRDs - retry a handful of times.
  local manifest attempt=0
  manifest="$(cat <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: $acme_server
    email: $acme_email
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
YAML
  )"

  while [ $attempt -lt 10 ]; do
    if printf '%s\n' "$manifest" | kctl apply -f - >/dev/null 2>&1; then
      ok "ClusterIssuer letsencrypt applied"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 5
  done
  die "could not apply ClusterIssuer after retries"
}

install_metrics_server() {
  info "installing metrics-server"
  hctl repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
  hctl repo update metrics-server >/dev/null

  # Talos kubelets use self-signed serving certs by default, so the
  # metrics-server must skip kubelet TLS verification. InternalIP is the
  # only address type Talos surfaces for nodes.
  hctl upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version "$METRICS_SERVER_CHART_VERSION" \
    --set "args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP}" \
    --wait --timeout 5m
  ok "metrics-server installed"
}

install_storage() {
  info "installing local-path-provisioner (default StorageClass: local-path)"

  # PSA "restricted" is the default; local-path-provisioner runs a helper
  # pod that needs hostPath. Pre-label the namespace as privileged.
  kctl create namespace local-path-storage --dry-run=client -o yaml | kctl apply -f - >/dev/null
  kctl label --overwrite namespace local-path-storage \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged >/dev/null

  # Upstream manifest; node path defaults to /opt/local-path-provisioner
  # which is read-only on Talos. Patch the ConfigMap to use /var which is
  # the persistent ephemeral mount Talos exposes to workloads.
  local manifest_url="https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml"
  curl -fsSL "$manifest_url" \
    | sed -e 's#/opt/local-path-provisioner#/var/local-path-provisioner#g' \
    | kctl apply -f - >/dev/null

  kctl annotate --overwrite storageclass local-path \
    storageclass.kubernetes.io/is-default-class=true >/dev/null

  kctl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=2m
  ok "local-path storage installed (default StorageClass: local-path, node path: /var/local-path-provisioner)"
}

cmd_platform() {
  check_prereqs
  [ -f "$KUBECONFIG_FILE" ] || die "no kubeconfig; run \`$0 bootstrap\` first"

  section "Platform: storage + metrics-server + Traefik + cert-manager + Let's Encrypt"
  ensure_api_access
  wait_for_apiserver
  install_storage
  install_metrics_server
  install_traefik
  install_cert_manager
  install_letsencrypt_issuer
}

# ---------- auto-upgrades ------------------------------------------------------

cmd_upgrades() {
  check_prereqs
  [ -f "$KUBECONFIG_FILE" ] || die "no kubeconfig; run \`$0 bootstrap\` first"
  [ -f "$TALOSCONFIG_FILE" ] || die "no talosconfig; run \`$0 bootstrap\` first"

  section "Installing system-upgrade-controller"

  ensure_api_access
  wait_for_apiserver
  kctl apply -f "$SUC_CRD_URL"
  kctl apply -f "$SUC_URL"
  kctl -n system-upgrade rollout status deploy/system-upgrade-controller --timeout=5m

  info "mounting talosconfig as a Secret in system-upgrade namespace"
  kctl -n system-upgrade create secret generic talosconfig \
    --from-file=config="$TALOSCONFIG_FILE" \
    --dry-run=client -o yaml | kctl apply -f -

  info "rendering Talos / Kubernetes upgrade plans"
  local schematic_id rendered k8s_target talos_target
  schematic_id="$(jq -r '.talos_schematic_id // "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"' "$TFVARS_FILE" 2>/dev/null \
    || echo ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515)"
  k8s_target="$(resolve_kubernetes_target_version)"
  talos_target="$(resolve_talos_target_version)"
  info "kubernetes upgrade target: $k8s_target (cap $KUBERNETES_MAX_MINOR_VERSION)"
  info "talos upgrade target: $talos_target (cap $TALOS_MAX_MINOR_VERSION)"
  rendered="$LOCAL_DIR/upgrade-plans.yaml"
  sed \
    -e "s|\${talos_version}|$talos_target|g" \
    -e "s|\${kubernetes_version}|$k8s_target|g" \
    -e "s|\${talos_schematic_id}|$schematic_id|g" \
    -e "s|\${talosctl_image_tag}|$TALOSCTL_IMAGE_TAG|g" \
    "$MANIFESTS_DIR/talos-upgrade-plan.yaml.tftpl" > "$rendered"
  kctl apply -f "$rendered"

  info "installing upgrade resolver CronJobs (daily patch tracking)"
  local k8s_resolver talos_resolver k8s_max_minor talos_max_minor
  k8s_max_minor="${KUBERNETES_MAX_MINOR_VERSION#*.}"
  talos_max_minor="${TALOS_MAX_MINOR_VERSION#*.}"
  k8s_resolver="$LOCAL_DIR/kubernetes-upgrade-resolver.yaml"
  talos_resolver="$LOCAL_DIR/talos-upgrade-resolver.yaml"
  sed -e "s|\${k8s_max_minor}|$k8s_max_minor|g" \
    "$MANIFESTS_DIR/kubernetes-upgrade-resolver.yaml.tftpl" > "$k8s_resolver"
  sed -e "s|\${talos_max_minor}|$talos_max_minor|g" \
    "$MANIFESTS_DIR/talos-upgrade-resolver.yaml.tftpl" > "$talos_resolver"
  kctl apply -f "$k8s_resolver"
  kctl apply -f "$talos_resolver"

  ok "auto-upgrade plans applied; SUC reconciles Talos + Kubernetes; resolvers track patches"
  kctl -n system-upgrade get plans
}

# Compute the K8s version SUC should upgrade to: one minor above the cluster's
# current node version, clamped to KUBERNETES_MAX_MINOR_VERSION, then resolved
# to the latest patch via dl.k8s.io's per-minor "stable" pointer. Re-running
# this command walks the cluster forward one hop per invocation - talosctl's
# `upgrade-k8s` refuses multi-minor jumps.
resolve_kubernetes_target_version() {
  local current minor_cap cur_minor next_minor patch
  current="$(kctl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null | sed 's/^v//')"
  [ -n "$current" ] || die "could not read current Kubernetes version from cluster"
  cur_minor="${current%.*}"   # 1.33.0 -> 1.33
  cur_minor="${cur_minor#*.}" # 1.33   -> 33
  minor_cap="${KUBERNETES_MAX_MINOR_VERSION#*.}"  # 1.35 -> 35

  if [ "$cur_minor" -ge "$minor_cap" ]; then
    next_minor="$minor_cap"
  else
    next_minor=$((cur_minor + 1))
  fi

  patch="$(curl -fsSL "https://dl.k8s.io/release/stable-1.${next_minor}.txt" 2>/dev/null \
    || die "could not fetch latest patch for Kubernetes 1.${next_minor}")"
  printf '%s' "$patch"
}

# Compute the Talos version SUC should upgrade to: latest stable patch of
# the cluster's current minor, or one minor above it, clamped to
# TALOS_MAX_MINOR_VERSION. Mirrors resolve_kubernetes_target_version - the
# in-cluster resolver CronJob runs this same logic daily.
resolve_talos_target_version() {
  local os_image current cur_minor minor_cap next_minor target
  os_image="$(kctl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null)"
  [ -n "$os_image" ] || die "could not read current Talos version from cluster"
  current="$(printf '%s' "$os_image" | sed -n 's/.*v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  [ -n "$current" ] || die "could not parse Talos version from osImage: $os_image"
  cur_minor="${current%.*}"; cur_minor="${cur_minor#*.}"
  minor_cap="${TALOS_MAX_MINOR_VERSION#*.}"

  if [ "$cur_minor" -ge "$minor_cap" ]; then
    next_minor="$minor_cap"
  else
    next_minor=$((cur_minor + 1))
  fi

  target="$(curl -fsSL "https://api.github.com/repos/siderolabs/talos/releases?per_page=100" 2>/dev/null \
    | jq -r '.[] | select(.prerelease == false) | .tag_name' \
    | grep -E "^v1\.${next_minor}\.[0-9]+$" \
    | sort -V | tail -1)"
  [ -n "$target" ] || die "could not find latest patch for Talos 1.${next_minor}"
  printf '%s' "$target"
}

# ---------- kubeconfig helper --------------------------------------------------

cmd_kubeconfig() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; run \`$0\` first"
  write_local_configs
  say ""
  say "Export these to use the cluster:"
  say ""
  say "  export KUBECONFIG=$KUBECONFIG_FILE"
  say "  export TALOSCONFIG=$TALOSCONFIG_FILE"
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
  export KUBECONFIG=$KUBECONFIG_FILE
  export TALOSCONFIG=$TALOSCONFIG_FILE
  $0 bootstrap     # apply Talos config + bootstrap etcd
  $0 platform      # install Traefik + cert-manager + Let's Encrypt issuer
  $0 install       # helm install vyhub chart
  $0 upgrades      # install SUC + auto-update plans
  $0 redeploy      # nuke + reprovision (requires typing the server name)
  $0 destroy       # tear down

Cluster:
  kubectl --kubeconfig $KUBECONFIG_FILE get pods -A
  talosctl --talosconfig $TALOSCONFIG_FILE dashboard
EOF
}

cmd_destroy() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; nothing to destroy"
  warn "This will permanently delete the Hetzner server, firewall and SSH keys created by this setup."
  prompt_yes_no "Proceed with destroy?" n || die "aborted"
  ( cd "$TOFU_DIR" && tofu destroy -auto-approve )
  rm -rf "$LOCAL_DIR"
}

cmd_redeploy() {
  check_prereqs
  [ -f "$TFVARS_FILE" ] || die "no $TFVARS_FILE; run \`$0\` first"

  local server_name
  server_name="$(jq -r '.server_name // "vyhub-onprem"' "$TFVARS_FILE")"

  section "Redeploy"
  warn "This will DESTROY the current server (including all PV data) and"
  warn "provision a fresh one from scratch."
  say ""
  say "  Server: ${C_BOLD}$server_name${C_RST}"
  say ""
  say "Type the server name to confirm: "
  local reply
  read -r reply
  [ "$reply" = "$server_name" ] || die "confirmation did not match — aborted"

  ( cd "$TOFU_DIR" && tofu destroy -auto-approve )
  rm -rf "$LOCAL_DIR"
  ( cd "$TOFU_DIR" && tofu apply -auto-approve )
  cmd_bootstrap
  cmd_platform
  cmd_upgrades
  cmd_install

  ok "server redeployed"
  cmd_outputs
}

cmd_full() {
  check_prereqs
  intro
  ask_token
  ask_location
  ask_server_type
  ask_registry_login
  ask_env_vars
  ask_acme_email
  ask_backups
  write_tfvars
  run_tofu_apply
  cmd_outputs

  cmd_bootstrap
  cmd_firewall
  cmd_platform
  cmd_upgrades
  cmd_install

  section "Done"
  local frontend
  frontend="$(jq -r '.vyhub_env.VYHUB_FRONTEND_URL' "$SCRIPT_DIR/.vyhub.install.json")"
  ok "VyHub onprem cluster bootstrapped"
  ok "Once DNS + ingress TLS are in place, app should be reachable at $frontend"
}

main() {
  local cmd="${1:-full}"
  case "$cmd" in
    full|"")    cmd_full ;;
    apply)      cmd_apply ;;
    bootstrap)  cmd_bootstrap ;;
    platform)   cmd_platform ;;
    install)    cmd_install ;;
    upgrades)   cmd_upgrades ;;
    firewall)   cmd_firewall ;;
    kubeconfig) cmd_kubeconfig ;;
    outputs)    cmd_outputs ;;
    redeploy)   cmd_redeploy ;;
    destroy)    cmd_destroy ;;
    -h|--help|help)
      sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)          die "unknown subcommand: $cmd (try --help)" ;;
  esac
}

main "$@"
