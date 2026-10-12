variable "cluster_name" {
  description = "Name of the DOKS cluster. Also names the VPC, the node pool and the DigitalOcean load balancer."
  type        = string
  default     = "dev-cluster"
}

variable "region" {
  description = "DigitalOcean region slug (e.g. lon1, fra1, nyc3)"
  type        = string
  default     = "lon1"
}

variable "kubernetes_version_prefix" {
  description = "Match the newest patch release of this minor version"
  type        = string
  default     = "1.34."
}

variable "node_size" {
  description = "Droplet size for worker nodes"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_count" {
  description = "Starting node count"
  type        = number
  default     = 2
}

variable "node_min" {
  description = "Autoscaler minimum"
  type        = number
  default     = 2
}

variable "node_max" {
  description = "Autoscaler maximum"
  type        = number
  default     = 4
}

variable "app_namespace" {
  description = <<-EOT
    Namespace the LogiTrack chart is released into.

    Load-bearing: the chart's logging.fluentbit.namespaces is a hardcoded grep
    filter defaulting to ["logitrack-dev"], while its Fluent Bit ClusterRoleBinding
    uses .Release.Namespace. Change this and logs stop arriving with no error.
  EOT
  type        = string
  default     = "logitrack-dev"
}

variable "domain" {
  description = "Registered domain. Its nameservers are NOT delegated to DigitalOcean - see dns.tf."
  type        = string
  default     = "kmdndd.name.ng"
}

variable "app_host" {
  description = "Hostname the chart serves on. Becomes ingress.host and the TLS certificate's commonName."
  type        = string
  default     = "dev.kmdndd.name.ng"
}

variable "manage_dns" {
  description = "Create the DigitalOcean DNS zone and records. Only turn on once the nameservers are delegated to DigitalOcean."
  type        = bool
  default     = false
}

variable "dns_record_names" {
  description = "Record names to point at the load balancer. '@' is the apex. Used for the output whether or not manage_dns is set."
  type        = list(string)
  # api.* are the gateway's own origins - the UI and API are cross-origin.
  default = ["@", "api", "dev", "api.dev"]
}

variable "lb_hostname" {
  description = <<-EOT
    Sets the do-loadbalancer-hostname annotation on the ingress Service.

    Leave empty on the first apply. Set it to app_host and re-apply only if an
    ACME challenge hangs in "pending" - see the comment in platform.tf.
  EOT
  type        = string
  default     = ""
}

variable "acme_email" {
  description = <<-EOT
    Let's Encrypt account contact.

    No resource here reads this. The ACME account is registered by the Issuer the
    application chart creates, not by Terraform. It lives here so the helm_command
    output is copy-pasteable and the value is recorded in one place.
  EOT
  type        = string
  default     = "itojedollars3@gmail.com"

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.acme_email))
    error_message = "Let's Encrypt rejects account registration without a valid contact address."
  }
}

variable "ghcr_server" {
  description = "Container registry host for the pull secret"
  type        = string
  default     = "ghcr.io"
}

variable "ghcr_username" {
  description = "GitHub username the pull token belongs to"
  type        = string
}

variable "ghcr_token" {
  description = "GitHub PAT with read:packages ONLY. Ends up in terraform.tfstate in plaintext - see README."
  type        = string
  sensitive   = true
}

variable "image_pull_secret_name" {
  description = "Name of the dockerconfigjson secret. Must match global.imagePullSecrets in the chart values."
  type        = string
  default     = "ghcr-pull"
}

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx chart version"
  type        = string
  default     = "4.14.5"
}

variable "cert_manager_chart_version" {
  description = "cert-manager chart version"
  type        = string
  default     = "v1.17.1"
}
