# vyhub-onprem installer

Two installation methods, sharing the same server-side installer
(`install.sh`):

- **Method 1 — provision a new Hetzner VM (`setup.sh`).** Laptop-side
  driver that provisions a fresh Hetzner Cloud VM with [OpenTofu], then
  hands off to `install.sh` on the VM via [cloud-init]. Use this when you
  don't have a server yet. → [Usage](#usage--provision-a-new-hetzner-vm)
- **Method 2 — install on an existing server (`install.sh`).**
  Server-side installer. Runs on any Debian/Ubuntu host you already
  manage. Installs Docker + dependencies, generates secrets, merges the
  VyHub env block, and brings the `docker compose` stack up. Supports a
  `--non-interactive` mode for your own automation.
  → [Usage](#usage--install-on-an-existing-debian-server)

[OpenTofu]: https://opentofu.org
[Hetzner Cloud]: https://www.hetzner.com/cloud
[cloud-init]: https://cloud-init.io

## What it does

1. `setup.sh` asks for a Hetzner Cloud API token, location, server type
   and SSH key.
2. `setup.sh` asks for a single VyHub config string. Generate it at
   <https://www.vyhub.net> → Setup dialog → **Automated (Hetzner Cloud)**
   and paste it on one line — it contains both the VyHub `VYHUB_*` env
   vars and the container registry credentials, encoded as
   base64-of-JSON, so no further parsing is needed.
3. OpenTofu creates:
   - an SSH key resource for each authorized key (existing keys already in
     the Hetzner project are detected and reused instead of re-uploaded),
   - a firewall that only allows TCP 22, 80, 443 (and ICMP),
   - a Debian 13 server (CAX11 / nbg1 by default) with that firewall.
4. Cloud-init on the server writes `/etc/vyhub-onprem-config.json` (a single
   JSON object holding the `env` vars and `registry` credentials), clones
   this repo to `/opt/vyhub-onprem`, and runs
   `setup/install.sh install --non-interactive`. The installer:
   - installs Docker (via `get.docker.com`), `git`, `certbot`, `fail2ban`,
     `jq`, `openssl`, and enables unattended security upgrades,
   - runs `first-setup.sh` to generate a baseline `.env` and
     `docker-compose.override.yml` (with random DB passwords / secrets),
   - merges your VyHub env vars into `.env` (de-duplicated),
   - drops a placeholder self-signed cert into `nginx/certs/`,
   - logs in to the container registry (if creds were provided),
   - `docker compose up -d` the stack and writes
     `/var/lib/vyhub-onprem-ready` when it's done.
5. `setup.sh` prints the A/AAAA records you need to create.
6. Optionally `setup.sh` runs `install.sh certbot ...` on the server to
   replace the self-signed cert with a Let's Encrypt cert for
   `VYHUB_FRONTEND_URL` (and installs a deploy hook so renewals are
   picked up automatically).

## Prerequisites

On your laptop:

- [`tofu`](https://opentofu.org/docs/intro/install/) >= 1.6
- `ssh`, `ssh-keygen`, `curl`, `jq`, `openssl`
- An SSH keypair (`~/.ssh/id_ed25519` or `~/.ssh/id_rsa`). Keys already
  loaded into your `ssh-agent` (`ssh-add -L`) are auto-detected and
  offered; otherwise you'll be prompted for a `.pub` file path.

In the cloud:

- A [Hetzner account](https://accounts.hetzner.com/signUp).
- A Hetzner Cloud project: <https://console.hetzner.cloud/projects> →
  **+ New project**.
- An API token with **Read & Write** permission on that project: open the
  project, **Security → API Tokens → Generate API Token**. Copy the token
  immediately - Hetzner only shows it once.

From <https://www.vyhub.net>:

- Your instance config string (open the Setup dialog on your instance,
  choose **Automated (Hetzner Cloud)** and copy the single string shown
  there). Have it on your clipboard before starting.

## Usage — provision a new Hetzner VM

```bash
cd setup
./setup.sh
```

The script is idempotent for the parts that matter. If something blows up
mid-way you can re-run individual steps:

```bash
./setup.sh apply      # re-run `tofu apply` with the saved tfvars
./setup.sh outputs    # show server IPs + management cheatsheet
./setup.sh wait       # block until cloud-init finishes (streams the log)
./setup.sh logs       # tail the cloud-init / install.sh output log
./setup.sh ssh        # ssh root@<server>
./setup.sh ssh "cd /opt/vyhub-onprem && docker compose logs -f"
./setup.sh certbot    # request / replace the Let's Encrypt cert
./setup.sh redeploy   # destroy + reprovision from scratch (typed confirm)
./setup.sh destroy    # delete the Hetzner resources
```

## Usage — install on an existing Debian server

If you already have a Debian/Ubuntu host (root access required), skip
OpenTofu entirely and run `install.sh` directly:

```bash
git clone https://github.com/matbyte-com/vyhub-onprem.git /opt/vyhub-onprem
cd /opt/vyhub-onprem
sudo ./setup/install.sh
```

You will be prompted to paste the single config string from the Setup
dialog at <https://www.vyhub.net> (the same base64 string `setup.sh`
consumes). It carries both the `VYHUB_*` env vars and the container
registry login.

Once DNS for `VYHUB_FRONTEND_URL` resolves to the server, request a
Let's Encrypt certificate:

```bash
sudo ./setup/install.sh certbot --email you@example.com
```

Non-interactive use (e.g. driven by your own automation) is supported by
pre-populating `/etc/vyhub-onprem-config.json` with a JSON object of the
form `{"env": {"VYHUB_*": "..."}, "registry": {"url": "...", "username":
"...", "password": "..."}}` and running:

```bash
sudo ./setup/install.sh install --non-interactive
```

State and inputs live under `setup/tofu/`:

- `terraform.tfvars.json` - the answers you gave (chmod 600, gitignored).
- `terraform.tfstate` - OpenTofu state (chmod 600, gitignored). **Don't
  delete this file** unless you also `tofu destroy` first, otherwise you
  will lose track of the resources.

## DNS step

After `tofu apply` the script prints the IPs and the records you need to
create. Create both `A` and `AAAA`. The script will not block on DNS - you
can either wait for propagation now and continue, or skip the cert step
and re-run `./setup.sh certbot` once the records have spread.

The script uses `dig` (if available) to warn you when DNS still points
somewhere else.

## TLS / Let's Encrypt

The cert step uses `certbot --standalone`, which needs to bind port 80.
The script briefly stops the `nginx` container, requests the cert, copies
the resulting fullchain/privkey into `/opt/vyhub-onprem/nginx/certs/` (the
paths the bundled `nginx/vyhub.conf` reads from), and starts nginx again.

A renewal deploy hook is installed at
`/etc/letsencrypt/renewal-hooks/deploy/vyhub-onprem.sh` so future renewals
(driven by the `certbot.timer` systemd timer) re-copy the cert and
restart nginx automatically. No cron entry to maintain.

## Layout

```
setup/
├── README.md                  - this file
├── setup.sh                   - laptop-side driver (OpenTofu + Hetzner)
├── install.sh                 - server-side installer (Debian/Ubuntu)
└── tofu/
    ├── versions.tf
    ├── variables.tf
    ├── main.tf                - hcloud_ssh_key(s), hcloud_firewall, hcloud_server
    ├── outputs.tf
    ├── cloud-init.yaml.tftpl  - writes env files + invokes install.sh
    └── .gitignore
```

## Maintenance — nightly auto-updates

`install.sh` installs a systemd timer that keeps the stack current with no
manual maintenance:

| Timer                              | Fires (local time) | Action                                                                 |
| ---------------------------------- | ------------------ | ---------------------------------------------------------------------- |
| `apt-daily-upgrade.timer`*         | ~01:00 ± 30 min    | `unattended-upgrades` installs Debian + Docker apt updates             |
| (auto-reboot)*                     | 02:00              | reboot if a kernel update required it                                  |
| `vyhub-onprem-update.timer`        | ~03:30 ± 30 min    | `git pull --ff-only && docker compose pull && docker compose up -d`    |

\* Configured only on Hetzner / cloud-init servers. On a manually
installed Debian host, only the container update timer is set up — the
server's existing apt policy is left untouched.

Inspect / control on the server:

```bash
systemctl list-timers --all | grep -E 'vyhub|apt-daily'
journalctl -u vyhub-onprem-update.service  # container update logs
journalctl -u unattended-upgrades.service  # OS upgrade logs
sudo /opt/vyhub-onprem/setup/install.sh update   # run a container update on demand
```

### Disk-fill safeguards

`install.sh` writes `/etc/docker/daemon.json` with a `10m × 3` json-file
log cap (skipped if the file already exists). Old Docker images are
pruned on every nightly update.

### Self-healing

`docker-compose.yml` runs a `willfarrell/autoheal` sidecar that restarts
any container reporting `unhealthy`. Every application service — `app`,
`db`, `nginx`, `db-backup`, `geoip-api`, `pdf-api`, and `loki` — has a
healthcheck and the `autoheal` label; if one hangs, autoheal restarts it
within ~30 s without operator intervention. Inspect with:

```bash
docker compose ps               # STATUS column shows (healthy)/(unhealthy)
docker compose logs autoheal
```

## Operational notes

- **Re-rendering cloud-init does NOT re-provision the server.** `main.tf`
  has `lifecycle { ignore_changes = [user_data, ssh_keys] }` to avoid
  destroying the VM if you tweak the env block. Apply changes by SSH'ing
  in and editing `/opt/vyhub-onprem/.env` directly, then
  `docker compose up -d` to pick them up.
- **Backups.** The script asks whether to enable Hetzner's daily snapshot
  backups (+20% on the server price). Enable in production - it's the
  cheapest disaster-recovery option here.
- **Updating the app.** Happens automatically nightly (see above). To
  trigger a manual update: ssh in and run
  `sudo /opt/vyhub-onprem/setup/install.sh update`.
- **Rotating secrets.** `VYHUB_SESSION_SECRET` / `VYHUB_CRYPT_SECRET` /
  the DB passwords are auto-generated by `first-setup.sh` on the server
  and never leave it. To rotate, log in and edit `.env` /
  `docker-compose.override.yml` directly.
- **Tearing down.** `./setup.sh destroy` removes the server, the
  firewall and the SSH key resource. Local state in `tofu/` and your
  Hetzner project itself are kept.

