#!/usr/bin/env bash
#
# vyhub-onprem server installer.
#
# Installs Docker + dependencies on a Debian/Ubuntu host and brings the
# vyhub-onprem stack up. Designed to work on both:
#   - a fresh cloud-init VM (driven by tofu/), and
#   - an existing Debian server (run manually after `git clone`).
#
# Usage:
#   sudo ./install.sh                            # interactive (paste the vyhub.net config string)
#   sudo ./install.sh install --non-interactive  # cloud-init path; expects /etc/vyhub-onprem-config.json
#   sudo ./install.sh certbot --email <addr> [--domain <host>]
#   sudo ./install.sh update                     # git pull + docker compose pull/up
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# Single JSON config of the shape produced by the vyhub.net Setup dialog:
#   { "env": { "VYHUB_*": "..." }, "registry": { "url", "username", "password" } }
# cloud-init writes this directly; interactively we decode it from the
# base64 string the dialog hands out (same string hcloud-setup.sh consumes).
CONFIG_FILE="${CONFIG_FILE:-/etc/vyhub-onprem-config.json}"
READY_FLAG="${READY_FLAG:-/var/lib/vyhub-onprem-ready}"

# Keep in sync with hcloud-setup.sh REQUIRED_VYHUB_KEYS.
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

NON_INTERACTIVE=0

# ---------- pretty printing ----------------------------------------------------

if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_BOLD=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi

say()     { printf '%s\n' "$*"; }
info()    { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()      { printf '%s ✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()    { printf '%s !%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()     { printf '%s ✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RST"; }

# ---------- helpers ------------------------------------------------------------

ensure_root() {
  [ "$(id -u)" -eq 0 ] || die "must be run as root (try: sudo $0 $*)"
}

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

env_value() {
  awk -v key="$1" '
    BEGIN { FS = "=" }
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^[[:space:]]*"|"[[:space:]]*$/, "")
      gsub(/^[[:space:]]*|[[:space:]]*$/, "")
      print
      exit
    }
  ' "$REPO_ROOT/.env"
}

# ---------- system bootstrap ---------------------------------------------------

install_packages() {
  section "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates curl git openssl jq \
    certbot fail2ban unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  ok "system packages ready"
}

configure_docker_daemon() {
  # Cap container log size so a chatty container can't fill the root fs.
  # Skip if the operator has their own /etc/docker/daemon.json already.
  local cfg=/etc/docker/daemon.json
  if [ -f "$cfg" ]; then
    info "leaving existing $cfg untouched"
    return 0
  fi
  mkdir -p /etc/docker
  cat > "$cfg" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  ok "wrote $cfg (10m × 3 log rotation)"
  # If dockerd is already running we need to restart it to pick up the new
  # config. On fresh installs the daemon isn't running yet — skip.
  if systemctl is-active --quiet docker; then
    systemctl restart docker
  fi
}

install_docker() {
  configure_docker_daemon
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "docker already installed"
  else
    section "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
}

# ---------- config ingestion ---------------------------------------------------

# Decode + validate the base64 config string; echoes the JSON on success.
decode_config_blob() {
  local blob="$1" decoded
  blob="${blob//[[:space:]]/}"
  [ -n "$blob" ] || return 1
  decoded="$(printf '%s' "$blob" | base64 -d 2>/dev/null)" || return 1
  printf '%s' "$decoded" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$decoded"
}

prompt_config_blob() {
  cat <<'EOF'
Open the Setup dialog at https://www.vyhub.net, select the "Automated"
install option and copy the single config string shown there. Paste it on
the line below and press Enter:

EOF
  local blob json
  while :; do
    read -r -p "> " blob || true
    if json="$(decode_config_blob "$blob")"; then
      break
    fi
    warn "could not decode the config string — please copy it again"
  done

  # Optional Steam key, injected into the env object.
  if [ "$(printf '%s' "$json" | jq -r '.env.VYHUB_AUTH_STEAM_KEY // empty')" = "" ]; then
    say ""
    say "  A Steam Web API key is needed for Steam login. Get one at:"
    say "  https://steamcommunity.com/dev/apikey"
    local steam_key
    steam_key="$(prompt "VYHUB_AUTH_STEAM_KEY (optional, press enter to skip)")"
    if [ -n "$steam_key" ]; then
      json="$(printf '%s' "$json" | jq --arg v "$steam_key" '.env.VYHUB_AUTH_STEAM_KEY = $v')"
    fi
  fi

  ( umask 077; printf '%s\n' "$json" > "$CONFIG_FILE" )
  chmod 600 "$CONFIG_FILE"
}

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    info "using existing $CONFIG_FILE"
  elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    die "$CONFIG_FILE is missing and --non-interactive is set"
  else
    section "VyHub instance configuration"
    prompt_config_blob
  fi

  jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die "$CONFIG_FILE is not valid JSON"

  local missing=()
  for k in "${REQUIRED_VYHUB_KEYS[@]}"; do
    if [ "$(jq -r --arg k "$k" '.env[$k] // empty' "$CONFIG_FILE")" = "" ]; then
      missing+=("$k")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "missing required env vars in $CONFIG_FILE: ${missing[*]}"
  fi
  ok "validated $CONFIG_FILE ($(jq '.env | length' "$CONFIG_FILE") env vars)"
}

# Render the env object to KEY="value" lines and merge into .env, replacing
# any keys already present in the baseline template.
merge_vyhub_env() {
  cd "$REPO_ROOT"
  local env_file
  env_file="$(mktemp)"
  chmod 600 "$env_file"
  jq -r '.env | to_entries[] | "\(.key)=\(.value | @json)"' "$CONFIG_FILE" > "$env_file"

  awk -v src="$env_file" '
    BEGIN {
      n = 0
      while ((getline line < src) > 0) {
        if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) continue
        eq = index(line, "=")
        if (!eq) continue
        userkeys[substr(line, 1, eq-1)] = 1
        userlines[n++] = line
      }
    }
    /# INSERT CONFIG FROM THE SETUP DIALOG ABOVE/ {
      print
      for (i = 0; i < n; i++) print userlines[i]
      next
    }
    {
      eq = index($0, "=")
      if (eq > 0 && substr($0, 1, eq-1) in userkeys) next
      print
    }
  ' .env > .env.tmp
  rm -f "$env_file"
  mv .env.tmp .env
  chmod 644 .env
  ok "merged VyHub env vars into .env"
}

# ---------- registry login -----------------------------------------------------

do_registry_login() {
  local url user pass
  url="$(jq  -r '.registry.url      // ""' "$CONFIG_FILE")"
  user="$(jq -r '.registry.username // ""' "$CONFIG_FILE")"
  pass="$(jq -r '.registry.password // ""' "$CONFIG_FILE")"
  if [ -z "$url" ] || [ -z "$user" ] || [ -z "$pass" ]; then
    info "no registry credentials in config; skipping docker login"
    return 0
  fi
  info "logging in to $url as $user"
  # Docker persists the credential in ~/.docker/config.json on success.
  printf '%s' "$pass" | docker login "$url" -u "$user" --password-stdin
}

# ---------- repo bootstrap -----------------------------------------------------

run_first_setup() {
  cd "$REPO_ROOT"
  if [ -f .env ] && [ -f docker-compose.override.yml ]; then
    info "gen-secrets.sh already executed"
    return 0
  fi
  section "Generating baseline .env and docker-compose.override.yml"
  bash ./gen-secrets.sh
}

ensure_placeholder_cert() {
  cd "$REPO_ROOT"
  mkdir -p nginx/certs
  if [ -f nginx/certs/vyhub.crt ]; then
    return 0
  fi
  info "generating placeholder self-signed cert"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -subj "/CN=$(hostname -f)" \
    -keyout nginx/certs/vyhub.key \
    -out    nginx/certs/vyhub.crt
  chmod 600 nginx/certs/vyhub.key
}

start_stack() {
  cd "$REPO_ROOT"
  section "Starting docker compose stack"
  docker compose pull
  docker compose up -d
  date -u +%FT%TZ > "$READY_FLAG"
  ok "stack is up; readiness flag at $READY_FLAG"
}

# ---------- nightly update timer ----------------------------------------------

setup_update_timer() {
  section "Installing nightly container update timer"

  cat > /etc/systemd/system/vyhub-onprem-update.service <<EOF
[Unit]
Description=vyhub-onprem nightly container update
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $REPO_ROOT/install.sh update
EOF

  cat > /etc/systemd/system/vyhub-onprem-update.timer <<'EOF'
[Unit]
Description=Nightly vyhub-onprem container update

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now vyhub-onprem-update.timer
  ok "vyhub-onprem-update.timer enabled (runs nightly ~03:30)"
}

# ---------- subcommands --------------------------------------------------------

cmd_install() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  ensure_root
  install_packages
  install_docker
  run_first_setup
  load_config
  merge_vyhub_env
  ensure_placeholder_cert
  do_registry_login
  start_stack
  setup_update_timer

  section "Done"
  local frontend
  frontend="$(env_value VYHUB_FRONTEND_URL || true)"
  if [ -n "$frontend" ]; then
    say ""
    say "Once your DNS records point to this server, the stack will be reachable at:"
    say "  ${C_BOLD}$frontend${C_RST}"
    say ""
    say "To request a Let's Encrypt certificate (DNS must already resolve here):"
    say "  sudo $0 certbot --email <you@example.com>"
  fi
}

cmd_update() {
  ensure_root
  cd "$REPO_ROOT"
  section "Updating vyhub-onprem"
  git pull --ff-only
  docker compose pull
  docker compose up -d --remove-orphans
  docker image prune -f
  ok "update finished"
}

cmd_certbot() {
  ensure_root
  local domain="" email=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) domain="$2"; shift 2 ;;
      --email)  email="$2";  shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  if [ -z "$domain" ]; then
    local frontend
    frontend="$(env_value VYHUB_FRONTEND_URL || true)"
    domain="$(printf '%s' "$frontend" | sed -E 's#^https?://##; s#/.*$##')"
  fi
  [ -n "$domain" ] || die "could not determine domain (use --domain or set VYHUB_FRONTEND_URL in .env)"
  [ -n "$email" ]  || die "--email is required"

  command -v certbot >/dev/null 2>&1 || die "certbot is not installed; run \`$0 install\` first"

  section "Let's Encrypt certificate for $domain"
  cd "$REPO_ROOT"

  # nginx serves the http-01 challenge from a shared webroot, so it must be
  # running. No downtime: the challenge is answered while nginx keeps serving.
  mkdir -p nginx/certbot-webroot
  docker compose up -d nginx

  certbot certonly --webroot -w "$REPO_ROOT/nginx/certbot-webroot" \
    --non-interactive --agree-tos --no-eff-email -m "$email" -d "$domain"

  mkdir -p nginx/certs
  install -m 644 "/etc/letsencrypt/live/$domain/fullchain.pem" nginx/certs/vyhub.crt
  install -m 600 "/etc/letsencrypt/live/$domain/privkey.pem"   nginx/certs/vyhub.key

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/vyhub-onprem.sh <<HOOK
#!/usr/bin/env bash
set -euo pipefail
DOMAIN="$domain"
TARGET="$REPO_ROOT"
case " \$RENEWED_DOMAINS " in
  *" \$DOMAIN "*)
    install -m 644 "/etc/letsencrypt/live/\$DOMAIN/fullchain.pem" "\$TARGET/nginx/certs/vyhub.crt"
    install -m 600 "/etc/letsencrypt/live/\$DOMAIN/privkey.pem"   "\$TARGET/nginx/certs/vyhub.key"
    cd "\$TARGET" && docker compose exec -T nginx nginx -s reload
    ;;
esac
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/vyhub-onprem.sh

  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  docker compose exec -T nginx nginx -s reload
  ok "cert installed for $domain; renewals handled by certbot.timer"
}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-install}"
  shift || true
  case "$cmd" in
    install)         cmd_install "$@" ;;
    update)          cmd_update "$@" ;;
    certbot)         cmd_certbot "$@" ;;
    -h|--help|help)  usage ;;
    *)               die "unknown subcommand: $cmd (try --help)" ;;
  esac
}

main "$@"
