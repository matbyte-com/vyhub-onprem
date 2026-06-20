# vyhub-onprem

This is the on-prem version of VyHub. (Also known as "Selfhosting")

## Installation methods

Pick whichever matches what you already have. The first two are automated
by the scripts in [`setup/`](setup/README.md) — see
[`setup/README.md`](setup/README.md) for the full walkthrough.

| Method | Use when | How |
|--------|----------|-----|
| **1. One-shot on Hetzner Cloud** | You have no server yet and want everything provisioned for you. | Run `cd setup && ./setup.sh` on your laptop. [OpenTofu] spins up a Debian 13 + Docker VM, clones this repo to it, applies your `VYHUB_*` env block, and optionally requests a Let's Encrypt cert. |
| **2. Existing Debian/Ubuntu server** | You already manage a host (any provider, or bare metal). | `git clone` this repo to the server and run `sudo ./setup/install.sh`. Installs Docker + dependencies, generates secrets, and brings the stack up. Supports a `--non-interactive` mode for your own automation. |
| **3. Fully manual** | You want to wire up `docker compose` yourself. | Follow the [docs](https://docs.vyhub.net/latest/getting_started/selfhosting/#installing). |

Methods 1 and 2 share the same server-side installer (`install.sh`) and
both set up nightly auto-updates, self-healing healthchecks, and daily DB
backups out of the box.

[OpenTofu]: https://opentofu.org

## Database backups

The `db-backup` service uses
[`prodrigestivill/postgres-backup-local`](https://github.com/prodrigestivill/docker-postgres-backup-local)
to take a daily `pg_dump` of the `vyhub` database and store it compressed
in the `vyhub-db-backups` Docker volume. Backups are kept according to this
retention policy:

| Tier | Kept |
|------|------|
| Daily | 7 dumps |
| Weekly | 4 dumps |
| Monthly | 6 dumps |

**Listing backups**

```bash
docker compose exec db-backup ls /backups/last /backups/weekly /backups/monthly
```

**Manually triggering a backup**

```bash
docker compose exec db-backup /backup.sh
```

**Restoring a backup**

```bash
# Pick a file, e.g. /backups/last/vyhub-2024-01-15T020000Z.sql.gz
docker compose exec db-backup \
  sh -c 'zcat /backups/last/<filename>.sql.gz | \
    psql --host=db --username=vyhub --dbname=vyhub'
```

The vyhub password is in `VYHUB_DB_PASSWORD` inside `.env`.

## Environment Variables

### General

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_SESSION_SECRET | String, >= 32 Chars | - | A random string with at least 32 chars
| VYHUB_BASE_URL | URL | - | The URL to the API (without `/v1`)
| VYHUB_ROOT_PATH | Path | - | When a reverse proxy *with* path stripping is used, set this to the stripped path. For example `/api`.
| VYHUB_PATH_PREFIX | Path | - | When a reverse proxy *without* path stripping is used, set this to path of the application. For example `/api`.
| VYHUB_FRONTEND_URL | URL | - | The URL where the Frontend is located
| VYHUB_GEOIP_API_URL | URL | - | The URL where the GeoIP API is located
| VYHUB_PDF_API_URL | URL | - | The URL where the PDF API is located
| VYHUB_CRYPT_SECRET | String, >= 32 Chars | - | A random string with at least 32 chars
| VYHUB_INSTANCE_ID | UUID | - | The VyHub instance ID
| VYHUB_INSTANCE_UID | Integer | - | The VyHub instance UID
| VYHUB_SECRET | Integer | - | The VyHub instance secret
| VYHUB_ADDONS | Comma seperated String | - | A comma seperated string of enabled addons. Example: `forum,addon2,addon3`
| VYHUB_CUSTOM_FRONTEND | true/false | false | If enabled, the `web` folder stays untouched and frontend files must be supplied manually

### Database

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_DATABASE_URL | URL | - | The postgres connection URL 
| VYHUB_DATABASE_SCHEMA | String | public | The used postgres schema
| VYHUB_DATABASE_MAX_WAIT | Integer | 30 | The maximum amount of seconds the application wait for the database to become available
| VYHUB_DATABASE_POOL_SIZE | Integer | 1 | The amount of connections that application always maintains to the database
| VYHUB_DATABASE_POOL_OVERFLOW | Integer | 14 | The maximum amount of connections that the application can establish additionally to the pool size. These connections will be closed if not needed anymore.

### Server

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_SERVER_DEBUG | true/false | false | Enables debug mode which causes stack traces to be printed. Should be false in production.
| VYHUB_SERVER_ECHO | true/false | false | Enables output of all SQL queries (to stdout)
| VYHUB_SERVER_SECURE | true/false | true | Enables HTTPS for the application. Not required with a reverse proxy (nginx).
| VYHUB_SERVER_GEN_CERT | true/false | false | Generates self-signed TLS certificates on startup for HTTPS
| VYHUB_SERVER_HOST | String | 0.0.0.0 | Sets the IP on which the application listens for requests
| VYHUB_SERVER_FORWARD_IPS | String | * | Specifies which IP-addresses are allowed to forward proxy traffic
| VYHUB_SERVER_PORT | Integer | 5050 | Specifies on which port the application listens
| VYHUB_SERVER_WORKERS | Integer | 1 | Specifies how many processes of the application are running. Can be slightly increased for more performance. (Caution: Make sure that enough memory (around 400MiB each) and postgres database connections (15 by default) are available)

### Mail

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_MAIL_FROM_ADDR | String | - | The sender address of mails sent by the application
| VYHUB_MAIL_SMTP_HOST | String | - | The IP/Hostname of the SMTP server
| VYHUB_MAIL_SMTP_PORT | Integer | 25 | The port of the SMTP server
| VYHUB_MAIL_SMTP_USER | String | - | The username to authenticate
| VYHUB_MAIL_SMTP_PASSWORD | String | - | The password to authenticate
| VYHUB_MAIL_SMTP_SSL | ssl/starttls | - | Enable SSL/StartTLS connection to the mailserver

### Logging

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_LOGGING_LOKI_URL | URL | - | The URL to the Loki logging server


### Web
| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_BACKEND_URL | URL | - | The URL to the API (with `/v1`)

