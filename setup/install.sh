#!/usr/bin/env bash
#
# vyhub-onprem server installer.
#
# Installs Docker + dependencies on a Debian/Ubuntu host and brings the
# vyhub-onprem stack up. Designed to work on both:
#   - a fresh cloud-init VM (driven by setup/tofu/), and
#   - an existing Debian server (run manually after `git clone`).
#
# Usage:
#   sudo ./setup/install.sh                            # interactive
#   sudo ./setup/install.sh install --non-interactive  # cloud-init path; expects /etc/vyhub-onprem.env
#   sudo ./setup/install.sh certbot --email <addr> [--domain <host>]
#   sudo ./setup/install.sh update                     # git pull + docker compose pull/up
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VYHUB_ENV_FILE="${VYHUB_ENV_FILE:-/etc/vyhub-onprem.env}"
REGISTRY_ENV_FILE="${REGISTRY_ENV_FILE:-/etc/vyhub-registry.env}"
READY_FLAG="${READY_FLAG:-/var/lib/vyhub-onprem-ready}"

# Keep in sync with setup/setup.sh REQUIRED_VYHUB_KEYS.
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

prompt_yes_no() {
  local message="$1" default="${2:-n}" reply
  local hint="[y/N]"
  [ "$default" = "y" ] && hint="[Y/n]"
  read -r -p "$message $hint: " reply || true
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
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

# ---------- vyhub env capture --------------------------------------------------

paste_env_block() {
  local out="$1"
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
  # Atomic write: stage in a tmpfile so a Ctrl-C mid-paste doesn't leave a
  # half-written $out that the next run mistakes for valid input.
  local tmp="${out}.tmp"
  ( umask 077; cat > "$tmp" )
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "no input received"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$out"
}

capture_vyhub_env() {
  if [ -f "$VYHUB_ENV_FILE" ]; then
    info "using existing $VYHUB_ENV_FILE"
  elif [ "$NON_INTERACTIVE" -eq 1 ]; then
    die "$VYHUB_ENV_FILE is missing and --non-interactive is set"
  else
    section "VyHub instance configuration"
    paste_env_block "$VYHUB_ENV_FILE"

    if ! grep -q '^[[:space:]]*VYHUB_AUTH_STEAM_KEY=' "$VYHUB_ENV_FILE"; then
      say ""
      say "  A Steam Web API key is needed for Steam login. Get one at:"
      say "  https://steamcommunity.com/dev/apikey"
      local steam_key
      steam_key="$(prompt "VYHUB_AUTH_STEAM_KEY (optional, press enter to skip)")"
      if [ -n "$steam_key" ]; then
        printf 'VYHUB_AUTH_STEAM_KEY="%s"\n' "$steam_key" >> "$VYHUB_ENV_FILE"
      fi
    fi
  fi

  local missing=()
  for k in "${REQUIRED_VYHUB_KEYS[@]}"; do
    if ! grep -qE "^[[:space:]]*${k}=" "$VYHUB_ENV_FILE"; then
      missing+=("$k")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "missing required vars in $VYHUB_ENV_FILE: ${missing[*]}"
  fi
  ok "validated $VYHUB_ENV_FILE"
}

merge_vyhub_env() {
  cd "$REPO_ROOT"
  awk -v src="$VYHUB_ENV_FILE" '
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
  mv .env.tmp .env
  chmod 644 .env
  ok "merged VyHub env vars into .env"
}

# ---------- registry login -----------------------------------------------------

paste_registry_login() {
  local out="$1"
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

  local reg_url reg_user reg_pass
  reg_url="$(printf  '%s' "$parsed" | cut -f1)"
  reg_user="$(printf '%s' "$parsed" | cut -f2)"
  reg_pass="$(printf '%s' "$parsed" | cut -f3)"
  [ -n "$reg_url" ]  || die "could not parse registry URL from command"
  [ -n "$reg_user" ] || die "could not parse -u from command"
  [ -n "$reg_pass" ] || die "could not parse -p from command"

  local tmp="${out}.tmp"
  ( umask 077; printf '%s\n%s\n%s\n' "$reg_url" "$reg_user" "$reg_pass" > "$tmp" )
  chmod 600 "$tmp"
  mv "$tmp" "$out"
  ok "registry credentials captured ($reg_user @ $reg_url)"
}

capture_registry_login() {
  if [ -f "$REGISTRY_ENV_FILE" ]; then
    info "using existing $REGISTRY_ENV_FILE"
    return 0
  fi
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    return 0
  fi
  section "Container registry"
  if prompt_yes_no "Configure a container registry login?" y; then
    paste_registry_login "$REGISTRY_ENV_FILE"
  fi
}

do_registry_login() {
  [ -f "$REGISTRY_ENV_FILE" ] || return 0
  local url user rc=0
  url="$(sed -n '1p' "$REGISTRY_ENV_FILE")"
  user="$(sed -n '2p' "$REGISTRY_ENV_FILE")"
  info "logging in to $url as $user"
  # Drop the plaintext password file regardless of login outcome.
  # Docker stores creds in ~/.docker/config.json on success.
  sed -n '3p' "$REGISTRY_ENV_FILE" \
    | docker login "$url" -u "$user" --password-stdin \
    || rc=$?
  rm -f "$REGISTRY_ENV_FILE"
  return "$rc"
}

# ---------- repo bootstrap -----------------------------------------------------

run_first_setup() {
  cd "$REPO_ROOT"
  if [ -f .env ] && [ -f docker-compose.override.yml ]; then
    info "first-setup.sh already executed"
    return 0
  fi
  section "Generating baseline .env and docker-compose.override.yml"
  bash ./first-setup.sh
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
ExecStart=/usr/bin/bash $REPO_ROOT/setup/install.sh update
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
  capture_vyhub_env
  capture_registry_login
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

  # Free port 80 so certbot --standalone can listen.
  docker compose stop nginx >/dev/null 2>&1 || true

  certbot certonly --standalone --non-interactive --agree-tos \
    --no-eff-email -m "$email" -d "$domain"

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
    cd "\$TARGET" && docker compose restart nginx
    ;;
esac
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/vyhub-onprem.sh

  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  docker compose up -d nginx
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
