variable "hcloud_token" {
  description = "Hetzner Cloud API token (read+write)."
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Name of the Hetzner Cloud server."
  type        = string
  default     = "vyhub-onprem"
}

variable "location" {
  description = "Hetzner Cloud location (e.g. nbg1, fsn1, hel1, ash, hil, sin)."
  type        = string
  default     = "nbg1"
}

variable "server_type" {
  description = "Hetzner Cloud server type (e.g. cax11, cax21, cpx11, cx22)."
  type        = string
  default     = "cax11"
}

variable "image" {
  description = "OS image used for the server."
  type        = string
  default     = "debian-13"
}

variable "ssh_public_keys" {
  description = "List of SSH public keys (full key strings) authorized for root access."
  type        = list(string)
  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "At least one SSH public key must be provided."
  }
}

variable "vyhub_env" {
  description = "Map of VYHUB_* env vars (and optional VYHUB_AUTH_STEAM_KEY) written to /opt/vyhub-onprem/.env on the server."
  type        = map(string)
  sensitive   = true
}

variable "repo_url" {
  description = "Git URL of the vyhub-onprem repo to clone on the server."
  type        = string
  default     = "https://github.com/matbyte-com/vyhub-onprem.git"
}

variable "repo_ref" {
  description = "Git ref (branch/tag/commit) of the vyhub-onprem repo to check out."
  type        = string
  default     = "master"
}

variable "registry_url" {
  description = "Container registry URL to authenticate against before pulling images (e.g. registry.matbyte.com)."
  type        = string
  default     = ""
}

variable "registry_user" {
  description = "Username for the container registry."
  type        = string
  sensitive   = true
  default     = ""
}

variable "registry_password" {
  description = "Password / token for the container registry."
  type        = string
  sensitive   = true
  default     = ""
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
