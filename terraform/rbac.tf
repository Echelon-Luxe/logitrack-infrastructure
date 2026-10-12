# The credential GitHub Actions deploys with. Scoped to logitrack-dev only, so a
# leaked CI secret cannot touch the cluster, the other namespaces, or DigitalOcean.
#
# This is why the deploy workflow does not get a DigitalOcean API token: that
# would let a compromised run delete the cluster itself.

resource "kubernetes_service_account_v1" "deployer" {
  metadata {
    name      = "logitrack-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}

# A manually created service-account token. DigitalOcean's kubeconfig credential
# expires after 7 days and TokenRequest tokens are bounded too - CI would start
# failing a week after setup. This kind does not expire.
resource "kubernetes_secret_v1" "deployer_token" {
  metadata {
    name      = "logitrack-deployer-token"
    namespace = kubernetes_service_account_v1.deployer.metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.deployer.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

resource "kubernetes_role_v1" "deployer" {
  metadata {
    name      = "logitrack-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  # Everything `helm upgrade --install --wait` touches for this chart. Helm 3
  # keeps release history in Secrets, which the first rule covers.
  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets", "services", "serviceaccounts", "pods", "events", "persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # So a failed rollout can print why, instead of just timing out.
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Write, not read-only: this chart creates its own Issuer and Certificate, so
  # the deployer has to be able to apply them.
  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["certificates", "issuers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "deployer" {
  metadata {
    name      = "logitrack-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.deployer.metadata[0].name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}
