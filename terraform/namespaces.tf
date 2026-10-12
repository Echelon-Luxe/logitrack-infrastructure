# Terraform owns this namespace, so `helm install` must NOT pass
# --create-namespace. Helm would adopt and annotate it, and the next apply would
# fight over ownership.
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace

    labels = {
      "name"                     = var.app_namespace
      "logitrack.io/environment" = "dev"

      # baseline is safe only because this cluster runs with logging.enabled=false
      # (see values-doks.yaml). Baseline forbids hostPath volumes, and the chart's
      # Fluent Bit DaemonSet mounts /var/log - so turning logging on here without
      # also relaxing enforce to "privileged" gets every fluent-bit pod rejected
      # by admission, with an error that reads nothing like a logging problem.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}
