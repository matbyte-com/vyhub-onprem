# vyhub-onprem one-shot installer

Interactive installer that provisions a Hetzner Cloud VM running
[Talos Linux] and installs the vyhub Helm chart from `charts.matbyte.com`
on top. Provisioning is driven by [OpenTofu] against the [Hetzner Cloud]
provider; the cluster install is driven by `talosctl` + `helm`.
Talos and Kubernetes auto-update via Rancher's
[system-upgrade-controller].

[Talos Linux]: https://www.talos.dev
[OpenTofu]: https://opentofu.org
[Hetzner Cloud]: https://www.hetzner.com/cloud
[system-upgrade-controller]: https://github.com/rancher/system-upgrade-controller

## What it does

1. Asks for a Hetzner Cloud API token, location, server type, registry
   login, the VyHub instance env block (generated at
   <https://www.vyhub.net>) and an e-mail address for Let's Encrypt.
2. Creates with OpenTofu:
   - a firewall allowing TCP 22, 80, 443, 6443 (kube-apiserver) and 50000
     (talosctl), plus ICMP,
   - a single Hetzner Cloud server (CAX21 / nbg1 by default) with the
     public Hetzner Talos ISO attached.
3. Generates a single-node controlplane Talos machine config (the
   `siderolabs/talos` provider produces a fresh PKI bundle) and applies
   it via `talosctl --insecure` while the server is still on the ISO.
4. Detaches the ISO via the Hetzner API and waits for the disk-installed
   Talos to come back up.
5. `talosctl bootstrap`s etcd, fetches the kubeconfig and stashes it in
   `./.local/kubeconfig`.
6. **Platform**: installs Traefik (as a hostNetwork DaemonSet bound to the
   node's :80 / :443) and cert-manager via their official Helm charts,
   then applies a `letsencrypt` `ClusterIssuer` (HTTP-01 solver against
   the Traefik ingressClass).
7. Installs the `system-upgrade-controller`, mounts the rendered
   `talosconfig` as a Secret, and applies channel-tracked Talos and
   Kubernetes upgrade `Plan`s. From there on, releases roll out
   automatically on every reconcile.
8. Creates a Docker-registry pull secret in the `vyhub` namespace and runs
   `helm upgrade --install vyhub $VYHUB_CHART_REF` (default:
   `oci://charts.matbyte.com/vyhub-test/vyhub-test` — the feature-branch
   build; set `VYHUB_CHART_REF=oci://charts.matbyte.com/vyhub/vyhub` for
   production, or point at a local `.tgz` artifact) with the captured env
   vars passed through `app.config.*` and `app.extraEnvVars`. The
   chart's Ingress is enabled with
   `ingressClassName: traefik`, host = `VYHUB_FRONTEND_URL`, and the
   `cert-manager.io/cluster-issuer: letsencrypt` annotation — cert-manager
   will request a Let's Encrypt cert on first reconcile.

## Prerequisites

On your laptop:

- [`tofu`](https://opentofu.org/docs/intro/install/) >= 1.6
- [`talosctl`](https://www.talos.dev/v1.10/talos-guides/install/talosctl/)
  matching the Talos version installed (default `v1.10.0`)
- `kubectl`, `helm` >= 3.12 (OCI support)
- `curl`, `jq`

In the cloud:

- A [Hetzner account](https://accounts.hetzner.com/signUp).
- A Hetzner Cloud project: <https://console.hetzner.cloud/projects> →
  **+ New project**.
- An API token with **Read & Write** permission on that project.

From <https://www.vyhub.net>:

- Your instance env block (eight `VYHUB_*` lines).
- The `docker login registry.matbyte.com -u … -p …` command from the
  setup page.

## Usage

```bash
cd setup
./setup.sh
```

The script is idempotent for the parts that matter. If something blows up
mid-way you can re-run individual phases:

```bash
./setup.sh apply        # re-run `tofu apply` with the saved tfvars
./setup.sh bootstrap    # apply Talos config + bootstrap etcd
./setup.sh platform     # install Traefik + cert-manager + LE ClusterIssuer
./setup.sh upgrades     # (re)install SUC + auto-update plans
./setup.sh install      # helm upgrade --install vyhub
./setup.sh kubeconfig   # write kubeconfig + talosconfig to ./.local
./setup.sh outputs      # show server IPs + management cheatsheet
./setup.sh destroy      # delete the Hetzner resources
```

State and inputs live under `setup/`:

- `tofu/terraform.tfvars.json` — answers you gave (chmod 600, gitignored).
- `tofu/terraform.tfstate` — OpenTofu state, including the Talos PKI
  bundle (chmod 600, gitignored). **Don't delete this file** unless you
  also `tofu destroy` first.
- `.vyhub.install.json` — captured registry creds + env vars used by
  `helm install` (chmod 600, gitignored).
- `.local/` — rendered `kubeconfig`, `talosconfig`, machine config and
  Helm values (gitignored).

## Auto-updates

Two `Plan` resources under the `system-upgrade` namespace drive
auto-updates (`setup/manifests/talos-upgrade-plan.yaml.tftpl`):

- **talos-upgrade** — polls `https://github.com/siderolabs/talos/releases/latest`,
  runs `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<resolved-version> --preserve`.
- **kubernetes-upgrade** — polls `https://dl.k8s.io/release/stable.txt`,
  runs `talosctl upgrade-k8s --to <resolved-version>`, gated by a
  `talosctl health` prepare step so it waits for in-flight node upgrades.

Both plans mount the cluster's `talosconfig` as a Secret. To pin to a
specific version (or pause updates) edit `setup/manifests/talos-upgrade-plan.yaml.tftpl`,
re-run `./setup.sh upgrades`.

## DNS / TLS

The `./setup.sh platform` phase brings up the TLS pipeline:

- **Traefik** is the IngressClass (`traefik`) for the cluster. It runs as
  a `DaemonSet` with `hostNetwork: true` so the node's public :80 / :443
  go straight to it — no cloud-LB is needed on a single-node setup.
- **cert-manager** runs in the `cert-manager` namespace with its CRDs
  installed.
- A `ClusterIssuer` named `letsencrypt` is applied with an HTTP-01
  solver targeting the Traefik ingressClass. By default it uses the
  Let's Encrypt **production** endpoint; the interactive flow offers a
  staging toggle for testing (no rate limits, untrusted certs).

The vyhub Helm chart's Ingress is rendered with
`cert-manager.io/cluster-issuer: letsencrypt` and `tls: true`, so on
first install cert-manager picks up the Ingress, runs the HTTP-01
challenge against the host (must resolve to the server's IP first), and
stores the cert as `<host>-tls`. Renewals are handled by cert-manager;
nothing else to do.

To switch to LE staging after the fact, edit the `ClusterIssuer`:
`kubectl edit clusterissuer letsencrypt`.

## Layout

```
setup/
├── README.md                                - this file
├── setup.sh                                 - interactive driver
├── manifests/
│   └── talos-upgrade-plan.yaml.tftpl        - Talos / k8s SUC Plans
└── tofu/
    ├── versions.tf                          - hcloud + siderolabs/talos providers
    ├── variables.tf
    ├── main.tf                              - firewall, server (ISO), Talos config
    ├── outputs.tf                           - kubeconfig + talosconfig outputs
    └── .gitignore
```

## Operational notes

- **The whole flow rebuilds idempotently.** Re-running `./setup.sh`
  picks up the cached tfvars and re-applies. `bootstrap` skips when
  etcd is already up; `install` becomes a `helm upgrade`.
- **Backups.** The script asks whether to enable Hetzner's daily snapshot
  backups (+20% on the server price). Enable in production - the only
  PV storage on a single-node Talos cluster is the node disk.
- **Architecture caveat.** CAX-series servers are ARM64. The bundled
  chart's images must be available for `linux/arm64`; pick `cpx*` /
  `cx*` if you need amd64.
- **Tearing down.** `./setup.sh destroy` removes the server, the firewall
  and the SSH key resources, and wipes the local `./.local/` directory.
  Hetzner project itself is kept.
