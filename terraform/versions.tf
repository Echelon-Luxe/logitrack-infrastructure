terraform {
  required_version = ">= 1.9"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.100"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}

provider "digitalocean" {
  # Reads DIGITALOCEAN_TOKEN from the environment. Keeping it out of tfvars means
  # the token is never written to disk here.
}

# Both providers below are configured from the cluster this same run creates.
# The credential in kube_config is DigitalOcean's short-lived one, but it is
# re-read from the API on every refresh, so it is never used stale - which is why
# there is no kubeconfig file and no exec plugin anywhere in this stack.
#
# The cost is that on a first apply these attributes are unknown at plan time.
# See the targeted first apply in README.md.
provider "kubernetes" {
  host                   = digitalocean_kubernetes_cluster.main.endpoint
  cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  token                  = digitalocean_kubernetes_cluster.main.kube_config[0].token
}

provider "helm" {
  # helm provider v3: `kubernetes` is an object attribute, not a nested block.
  kubernetes = {
    host                   = digitalocean_kubernetes_cluster.main.endpoint
    cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
    token                  = digitalocean_kubernetes_cluster.main.kube_config[0].token
  }
}
