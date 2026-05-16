locals {
  is_arm = can(regex("^cax", var.server_type))

  # Hetzner ships separate Talos ISO names for x86 and ARM since 2025-04-23.
  talos_iso = local.is_arm ? var.talos_iso_name_arm : var.talos_iso_name

  arch            = local.is_arm ? "arm64" : "amd64"
  talos_installer = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"

  ssh_key_fingerprints = [for k in var.ssh_public_keys : sha256(k)]
}

resource "hcloud_ssh_key" "this" {
  for_each = {
    for idx, key in var.ssh_public_keys :
    substr(local.ssh_key_fingerprints[idx], 0, 12) => key
  }

  name       = "${var.server_name}-${each.key}"
  public_key = each.value
  labels     = var.labels
}

resource "hcloud_firewall" "this" {
  name   = "${var.server_name}-fw"
  labels = var.labels

  rule {
    description = "Talos API (talosctl) - restricted to admin CIDRs"
    direction   = "in"
    protocol    = "tcp"
    port        = "50000"
    source_ips  = var.admin_cidrs
  }

  rule {
    description = "Kubernetes API server - restricted to admin CIDRs"
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = var.admin_cidrs
  }

  rule {
    description = "HTTP (also used for ACME http-01 challenge)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "HTTPS"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "ICMP"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "this" {
  name        = var.server_name
  server_type = var.server_type
  # Hetzner requires _some_ image even when booting from ISO; the disk gets
  # overwritten by the Talos installer during the first apply-config.
  image    = local.is_arm ? "debian-12" : "debian-12"
  location = var.location
  backups  = var.enable_backups
  iso      = local.talos_iso
  ssh_keys = [for k in hcloud_ssh_key.this : k.id]
  labels   = var.labels

  firewall_ids = [hcloud_firewall.this.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    # Detaching the ISO after Talos has installed to disk is done out-of-band
    # by setup.sh via the Hetzner API; don't let tofu re-attach it on apply.
    ignore_changes = [iso, ssh_keys]
  }
}

# ---------- Talos machine config ---------------------------------------------

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.server_name
  cluster_endpoint   = "https://${hcloud_server.this.ipv4_address}:6443"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          # Single-node: install to the only disk and use the Hetzner-factory
          # image so the installed system keeps the Hetzner-friendly schematic.
          disk  = "/dev/sda"
          image = local.talos_installer
        }
        # Talos 1.12 generates a separate `HostnameConfig` document with
        # `auto: stable`; setting `machine.network.hostname` here would
        # conflict ("static hostname is already set in v1alpha1 config").
        # Allow workloads to schedule on the (only) control-plane node.
        nodeLabels = {
          "node.kubernetes.io/exclude-from-external-load-balancers" = "true"
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = true
      }
    }),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.server_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [hcloud_server.this.ipv4_address]
  nodes                = [hcloud_server.this.ipv4_address]
}
