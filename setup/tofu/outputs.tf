output "server_id" {
  description = "Hetzner Cloud server ID."
  value       = hcloud_server.this.id
}

output "ipv4_address" {
  description = "Public IPv4 address of the server."
  value       = hcloud_server.this.ipv4_address
}

output "ipv6_address" {
  description = "Public IPv6 address of the server."
  value       = hcloud_server.this.ipv6_address
}

output "location" {
  description = "Hetzner Cloud location of the server."
  value       = hcloud_server.this.location
}

output "server_type" {
  description = "Hetzner Cloud server type."
  value       = hcloud_server.this.server_type
}

output "talos_machine_configuration" {
  description = "Rendered Talos controlplane machine configuration. Pipe through `talosctl apply-config --insecure`."
  value       = data.talos_machine_configuration.controlplane.machine_configuration
  sensitive   = true
}

output "talosconfig" {
  description = "Rendered talosconfig (client) for talosctl. Save to ~/.talos/config or pass via --talosconfig."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = "https://${hcloud_server.this.ipv4_address}:6443"
}

output "cluster_name" {
  description = "Talos / Kubernetes cluster name."
  value       = var.server_name
}

output "talos_installer_image" {
  description = "Factory-built Talos installer image used for upgrades."
  value       = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"
}
