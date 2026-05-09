# vyhub-onprem one-shot installer

Interactive installer that provisions a Hetzner Cloud VM and brings the
vyhub-onprem stack up on it. The provisioning is driven by [OpenTofu]
against the [Hetzner Cloud] provider; the in-VM bootstrap is driven by
[cloud-init].

[OpenTofu]: https://opentofu.org
[Hetzner Cloud]: https://www.hetzner.com/cloud
[cloud-init]: https://cloud-init.io

## What it does

1. Asks for a Hetzner Cloud API token, location, server type and SSH key.
2. Asks for the VyHub instance env block (the one generated at
   <https://www.vyhub.net>).
3. Creates with OpenTofu:
   - an SSH key resource for each authorized key,
   - a firewall that only allows TCP 22, 80, 443 (and ICMP),
   - a Debian 13 server (CAX11 / nbg1 by default) with that firewall.
4. Cloud-init on the server:
   - installs Docker (via `get.docker.com`), `git`, `certbot`, `fail2ban`
     and enables unattended security upgrades,
   - clones this repo to `/opt/vyhub-onprem`,
   - runs `first-setup.sh` to generate a baseline `.env` and
     `docker-compose.override.yml` (with random DB passwords / secrets),
   - merges your VyHub env vars into `.env` (de-duplicated),
   - drops a placeholder self-signed cert into `nginx/certs/`,
   - `docker compose up -d` the stack and writes
     `/var/lib/vyhub-onprem-ready` when it's done.
5. Prints the A/AAAA records you need to create.
6. Optionally runs `certbot` on the server to replace the self-signed cert
   with a Let's Encrypt cert for `VYHUB_FRONTEND_URL` (and installs a
   deploy hook so renewals are picked up automatically).

## Prerequisites

On your laptop:

- [`tofu`](https://opentofu.org/docs/intro/install/) >= 1.6
- `ssh`, `ssh-keygen`, `curl`, `jq`, `openssl`
- An SSH keypair (`~/.ssh/id_ed25519` or `~/.ssh/id_rsa`)

In the cloud:

- A [Hetzner account](https://accounts.hetzner.com/signUp).
- A Hetzner Cloud project: <https://console.hetzner.cloud/projects> →
  **+ New project**.
- An API token with **Read & Write** permission on that project: open the
  project, **Security → API Tokens → Generate API Token**. Copy the token
  immediately - Hetzner only shows it once.

From <https://www.vyhub.net>:

- Your instance env block (eight `VYHUB_*` lines). Have it on your
  clipboard before starting.

## Usage

```bash
cd setup
./setup.sh
```

The script is idempotent for the parts that matter. If something blows up
mid-way you can re-run individual steps:

```bash
./setup.sh apply      # re-run `tofu apply` with the saved tfvars
./setup.sh outputs    # show server IPs + management cheatsheet
./setup.sh wait       # block until cloud-init finishes
./setup.sh ssh        # ssh root@<server>
./setup.sh ssh "cd /opt/vyhub-onprem && docker compose logs -f"
./setup.sh certbot    # request / replace the Let's Encrypt cert
./setup.sh destroy    # delete the Hetzner resources
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
├── setup.sh                   - interactive driver
└── tofu/
    ├── versions.tf
    ├── variables.tf
    ├── main.tf                - hcloud_ssh_key, hcloud_firewall, hcloud_server
    ├── outputs.tf
    ├── cloud-init.yaml.tftpl  - in-VM bootstrap
    └── .gitignore
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
- **Updating the app.** `ssh` in, `cd /opt/vyhub-onprem`,
  `git pull && docker compose pull && docker compose up -d`.
- **Rotating secrets.** `VYHUB_SESSION_SECRET` / `VYHUB_CRYPT_SECRET` /
  the DB passwords are auto-generated by `first-setup.sh` on the server
  and never leave it. To rotate, log in and edit `.env` /
  `docker-compose.override.yml` directly.
- **Tearing down.** `./setup.sh destroy` removes the server, the
  firewall and the SSH key resource. Local state in `tofu/` and your
  Hetzner project itself are kept.

## Architecture caveat

CAX-series servers are ARM64. The bundled `docker-compose.yml` images
must be available for `linux/arm64` for the default flavor to work; if
you pick an x86 type (`cpx*`, `cx*`) you'll get amd64 images instead.
