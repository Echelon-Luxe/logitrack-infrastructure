# The patch version is never hardcoded: DigitalOcean retires patch releases, and
# a pinned slug turns the next plan into either a spurious diff or a "version not
# found" error. The prefix pins the minor and floats the patch.
data "digitalocean_kubernetes_versions" "current" {
  version_prefix = var.kubernetes_version_prefix
}

# Its own VPC rather than the region default, so `terraform destroy` reclaims the
# whole network and a second cluster in this region cannot share the subnet.
resource "digitalocean_vpc" "main" {
  name   = "${var.cluster_name}-vpc"
  region = var.region
}

resource "digitalocean_kubernetes_cluster" "main" {
  name     = var.cluster_name
  region   = var.region
  version  = data.digitalocean_kubernetes_versions.current.latest_version
  vpc_uuid = digitalocean_vpc.main.id

  # Patch upgrades apply during the maintenance window; surge upgrade adds a
  # replacement node before draining the old one, so a two-node pool does not
  # drop to one mid-upgrade.
  #
  # `version` is deliberately not in an ignore_changes: if DigitalOcean upgrades
  # past what the prefix selects, the next plan shows it. That is the signal you
  # want, not noise to suppress.
  auto_upgrade  = true
  surge_upgrade = true

  maintenance_policy {
    day        = "sunday"
    start_time = "03:00"
  }

  node_pool {
    name       = "${var.cluster_name}-workers"
    size       = var.node_size
    node_count = var.node_count

    auto_scale = true
    min_nodes  = var.node_min
    max_nodes  = var.node_max
  }

  tags = ["logitrack", "dev"]
}
