variable "hcloud_token" {
  description = "Hetzner Cloud API token (read+write)."
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Name of the Hetzner Cloud server (also used as the Talos cluster name)."
  type        = string
  default     = "vyhub-onprem"
}

variable "location" {
  description = "Hetzner Cloud location (e.g. nbg1, fsn1, hel1, ash, hil, sin)."
  type        = string
  default     = "nbg1"
}

variable "server_type" {
  description = "Hetzner Cloud server type (e.g. cax21, cpx21, cx22). Talos requires >=2GB RAM and >=2 vCPU; CAX11 is too small for k8s control-plane + workloads."
  type        = string
  default     = "cax21"
}

variable "ssh_public_keys" {
  description = "List of SSH public keys (full key strings) authorized for the Hetzner web console rescue path. Talos itself has no SSH, but Hetzner attaches these keys to the server resource for completeness."
  type        = list(string)
  default     = []
}

variable "talos_iso_name" {
  description = "Name of the Hetzner public Talos ISO (amd64). Hetzner ships these under the `hcloud-vX-Y-Z.{amd64,arm64}.iso` naming convention with schematic id ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515 (Hetzner + qemu-guest-agent)."
  type        = string
  default     = "hcloud-v1-12-4.amd64.iso"
}

variable "talos_iso_name_arm" {
  description = "Name of the Hetzner public Talos ISO for ARM (CAX) server types."
  type        = string
  default     = "hcloud-v1-12-4.arm64.iso"
}

variable "talos_version" {
  description = "Talos version to install/upgrade to. Must match the ISO version."
  type        = string
  default     = "v1.12.4"
}

variable "talos_schematic_id" {
  description = "Talos image factory schematic id for the installer image (Hetzner + qemu-guest-agent)."
  type        = string
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

variable "kubernetes_version" {
  description = "Kubernetes version to bootstrap (used by Talos)."
  type        = string
  default     = "1.33.0"
}

variable "enable_backups" {
  description = "Enable Hetzner Cloud backups for the server (+20% cost)."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to created Hetzner resources."
  type        = map(string)
  default = {
    managed-by = "vyhub-onprem-setup"
  }
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the Talos (50000) and Kubernetes (6443) APIs. Default is wide-open so the initial apply (before the cluster exists) succeeds; `setup.sh firewall` narrows it to the operator's current public IP."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
