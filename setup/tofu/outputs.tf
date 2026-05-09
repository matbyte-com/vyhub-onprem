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
