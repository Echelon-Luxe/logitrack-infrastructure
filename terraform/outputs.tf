output "cluster_name" {
  description = "DOKS cluster name"
  value       = digitalocean_kubernetes_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = digitalocean_kubernetes_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version DigitalOcean selected for the version prefix"
  value       = digitalocean_kubernetes_cluster.main.version
}

output "kubeconfig_command" {
  description = "Run once to point kubectl and helm at the cluster"
  value       = "doctl kubernetes cluster kubeconfig save ${digitalocean_kubernetes_cluster.main.name}"
}

output "ingress_ip" {
  description = "Public IP of the DigitalOcean load balancer in front of ingress-nginx"
  value       = local.ingress_ip
}

output "dns_records_to_create" {
  description = "A records to create wherever this domain's nameservers point. Terraform does not manage DNS (manage_dns = false)."
  value       = local.dns_records_to_create
}

output "app_namespace" {
  description = "Namespace to release the chart into. Do not pass --create-namespace."
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "image_pull_secret_name" {
  description = "Pass to the chart as global.imagePullSecrets[0].name"
  value       = kubernetes_secret_v1.ghcr.metadata[0].name
}

# Emitting the command keeps the Terraform/Helm boundary explicit and stops the
# namespace, host and pull secret name in it from drifting from what was created.
# It carries no secrets.
output "helm_command" {
  description = "Deploy the application chart. Terraform does not run this."
  value = join(" ", [
    "helm upgrade --install logitrack ./helm/logitrack",
    "--namespace ${kubernetes_namespace_v1.app.metadata[0].name}",
    "-f ./helm/logitrack/values.yaml",
    "-f ./helm/logitrack/values-doks.yaml",
    "--wait --timeout 10m",
  ])
}

# A self-contained kubeconfig built from the non-expiring ServiceAccount token
# rather than DigitalOcean's 7-day credential. Paste it into the infrastructure
# repository's KUBE_CONFIG secret:
#
#   terraform output -raw deployer_kubeconfig
#
# It can only act inside logitrack-dev - see rbac.tf.
output "deployer_kubeconfig" {
  description = "Base64 kubeconfig for the CI deploy ServiceAccount. Store as the KUBE_CONFIG secret."
  sensitive   = true
  value = base64encode(yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = digitalocean_kubernetes_cluster.main.name
      cluster = {
        server                     = digitalocean_kubernetes_cluster.main.endpoint
        certificate-authority-data = digitalocean_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
      }
    }]
    users = [{
      name = "logitrack-deployer"
      user = { token = kubernetes_secret_v1.deployer_token.data["token"] }
    }]
    contexts = [{
      name = "logitrack-dev"
      context = {
        cluster   = digitalocean_kubernetes_cluster.main.name
        user      = "logitrack-deployer"
        namespace = kubernetes_namespace_v1.app.metadata[0].name
      }
    }]
    current-context = "logitrack-dev"
  }))
}
