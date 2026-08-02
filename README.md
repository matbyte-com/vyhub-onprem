# vyhub-onprem

This is the on-prem version of VyHub. (Also known as "Selfhosting")

## Installation methods

Pick whichever matches what you already have. Methods 2 and 3 are
automated by the top-level scripts — see [`INSTALL.md`](INSTALL.md) for
the full walkthrough.

| Method | Use when | How |
|--------|----------|-----|
| **1. Install on a server with Docker / Docker Compose** | You already have a host with Docker and Docker Compose set up. | Follow the [docs](https://docs.vyhub.net/latest/getting_started/selfhosting/#installing) to wire up `docker compose` yourself. |
| **2. Existing Debian/Ubuntu server** | You manage a Debian/Ubuntu host (any provider, or bare metal) without Docker yet. | `git clone` this repo to the server and run `sudo ./install.sh`. Installs Docker + dependencies, generates secrets, and brings the stack up. Supports a `--non-interactive` mode for your own automation. |
| **3. One-shot on Hetzner Cloud** | You have no server yet and want everything provisioned for you. | Run `./hcloud-setup.sh` from a Linux machine (or WSL on Windows). [OpenTofu] spins up a Debian 13 + Docker VM, clones this repo to it, applies your `VYHUB_*` env block, and optionally requests a Let's Encrypt cert. |

Methods 2 and 3 share the same server-side installer (`install.sh`) and
both set up nightly auto-updates, self-healing healthchecks, and daily DB
backups out of the box.

[OpenTofu]: https://opentofu.org

## Environment Variables

### General

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_SESSION_SECRET | String, >= 32 Chars | - | A random string with at least 32 chars
| VYHUB_BASE_URL | URL | - | The URL to the API (without `/v1`)
| VYHUB_ROOT_PATH | Path | - | When a reverse proxy *without* path stripping is used, set this to path of the application. For example `/api`.
| VYHUB_FRONTEND_URL | URL | - | The URL where the Frontend is located
| VYHUB_GEOIP_API_URL | URL | - | The URL where the GeoIP API is located
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
| VYHUB_DATABASE_MAX_WAIT | Integer | 10 | The maximum amount of seconds the application wait for the database to become available
| VYHUB_DATABASE_POOL_SIZE | Integer | 1 | The amount of connections that application always maintains to the database
| VYHUB_DATABASE_POOL_OVERFLOW | Integer | 7 | The maximum amount of connections that the application can establish additionally to the pool size. These connections will be closed if not needed anymore.

### Auth

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_AUTH_STEAM_KEYS | Comma seperated String | - | One or more [Steam Web API keys](https://steamcommunity.com/dev/apikey). Requests are spread across every key given, so add more if you hit Steam's rate limits. A key configured in the admin panel takes precedence over this variable.
| VYHUB_AUTH_STEAM_KEY | String | - | **Deprecated**, use `VYHUB_AUTH_STEAM_KEYS`. Still honoured when the latter is unset.

### Server

| Var | Values | Default | Description |
|-----|------|---------|-------------|
| VYHUB_SERVER_DEBUG | true/false | false   | Enables debug mode which causes stack traces to be printed. Should be false in production.
| VYHUB_SERVER_ECHO | true/false | false   | Enables output of all SQL queries (to stdout)
| VYHUB_SERVER_SECURE | true/false | true    | Enables HTTPS for the application. Not required with a reverse proxy (nginx).
| VYHUB_SERVER_GEN_CERT | true/false | true    | Generates self-signed TLS certificates on startup for HTTPS
| VYHUB_SERVER_HOST | String | 0.0.0.0 | Sets the IP on which the application listens for requests
| VYHUB_SERVER_FORWARD_IPS | Comma seperated String | loopback + private ranges | Which peers may set the client IP via `X-Forwarded-For`. See [Client IPs behind a reverse proxy](#client-ips-behind-a-reverse-proxy).
| VYHUB_SERVER_TRUST_CLOUDFLARE | true/false | false | Take the client IP from Cloudflare's `CF-Connecting-IP` header. See [Client IPs behind a reverse proxy](#client-ips-behind-a-reverse-proxy).
| VYHUB_SERVER_PORT | Integer | 5050    | Specifies on which port the application listens
| VYHUB_SERVER_WORKERS | Integer | 2       | Specifies how many processes of the application are running. Can be slightly increased for more performance. (Caution: Make sure that for each worker, enough memory (around 500MiB) and postgres database connections (15 by default) are available)
| VYHUB_SERVER_MAX_REQUESTS | Integer | 10000   | Restart a worker after this many requests to bound memory growth. `0` disables recycling.
| VYHUB_SERVER_MAX_REQUESTS_JITTER | Integer | 1000    | Random spread added to `VYHUB_SERVER_MAX_REQUESTS`, so workers do not all recycle at the same moment.

#### Client IPs behind a reverse proxy

Rate limiting, GeoIP country detection (used for shop tax rates) and the
paysafecard webhook's IP allowlist all depend on the application seeing the real
client IP. Since a client can put anything in a forwarding header, the
application only accepts `X-Forwarded-For` when the request reaches it from a
peer listed in `VYHUB_SERVER_FORWARD_IPS`; otherwise it uses the address that
actually connected.

The default trusts loopback and every private/internal range
(`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`,
`100.64.0.0/10`, `::1/128`, `fc00::/7`, `fe80::/10`). This covers the Docker
network that the bundled `nginx` container talks to the app over, so the shipped
setup works unchanged. Only set this to `*` if the app is genuinely reached from
a public address — that lets **any** caller choose its own IP.

**If you run your own reverse proxy** in front of VyHub, make sure it sets
`X-Forwarded-For`, e.g. for nginx:

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

Without it every request appears to come from the proxy, so all your users share
a single rate-limit budget. `X-Real-IP` alone is **not** enough.

**Behind Cloudflare**, set `VYHUB_SERVER_TRUST_CLOUDFLARE=true`. Cloudflare's
edge servers have public addresses and so cannot be covered by
`VYHUB_SERVER_FORWARD_IPS`. Only enable this if your origin cannot be reached
directly, bypassing Cloudflare — otherwise anyone can send `CF-Connecting-IP`
and pick their own IP.

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
