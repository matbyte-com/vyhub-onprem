locals {
  ssh_key_fingerprints = [for k in var.ssh_public_keys : sha256(k)]

  # Values land inside single-quoted bash literals; escape embedded ' as '\''.
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname               = var.server_name
    ssh_keys               = var.ssh_public_keys
    coolify_admin_email    = replace(var.coolify_admin_email, "'", "'\\''")
    coolify_admin_password = replace(var.coolify_admin_password, "'", "'\\''")
    vyhub_fqdn             = replace(var.vyhub_fqdn, "'", "'\\''")
    vyhub_env              = var.vyhub_env
    registry_url           = replace(var.registry_url, "'", "'\\''")
    registry_user          = replace(var.registry_user, "'", "'\\''")
    registry_password      = replace(var.registry_password, "'", "'\\''")
    compose_url            = replace(var.compose_url, "'", "'\\''")
  })
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
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["0.0.0.0/0", "::/0"]
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
  image       = var.image
  location    = var.location
  backups     = var.enable_backups
  user_data   = local.cloud_init
  ssh_keys    = [for k in hcloud_ssh_key.this : k.id]
  labels      = var.labels

  firewall_ids = [hcloud_firewall.this.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    ignore_changes = [
      # user_data changes would force replacement; we manage post-boot
      # config via SSH instead of recreating the server.
      user_data,
      ssh_keys,
    ]
  }
}
