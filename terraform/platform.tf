locals {
  # The dots inside an annotation key are escaped: Helm's --set parser reads an
  # unescaped dot as a path separator and would nest the key six levels deep.
  ingress_nginx_set = [
    {
      name  = "controller.service.type"
      value = "LoadBalancer"
    },
    {
      # Preserves the client source IP, which the gateway's rate limiter needs to
      # do anything useful - without it every request appears to come from a node.
      name  = "controller.service.externalTrafficPolicy"
      value = "Local"
    },
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/do-loadbalancer-name"
      value = "${var.cluster_name}-ingress"
    },
    {
      name  = "controller.replicaCount"
      value = "2"
    },
    {
      # The class name is a hard contract with the application chart in two
      # places: its Ingress sets `ingressClassName: {{ .Values.ingress.className }}`
      # (default "nginx"), and the ACME HTTP-01 solver in its Issuer is pinned to
      # the same string. Set explicitly rather than inherited from the upstream
      # chart default, so a rename here is visible instead of mysterious.
      name  = "controller.ingressClassResource.name"
      value = "nginx"
    },
    {
      name  = "controller.ingressClassResource.default"
      value = "true"
    },
  ]

  # DOKS quirk, and the most likely reason a certificate never issues.
  #
  # With externalTrafficPolicy=Local, a pod cannot reach the load balancer's own
  # public IP - DigitalOcean does not hairpin that traffic back into the cluster.
  # cert-manager's HTTP-01 self-check does exactly that: it resolves the host,
  # gets the LB IP, and calls it from the cert-manager pod. When that times out
  # the Order sits "pending" forever, even though Let's Encrypt itself could
  # reach the challenge perfectly well.
  #
  # DigitalOcean's fix is to advertise the LB by hostname instead. That needs the
  # DNS record to already exist, and the IP is only known after the first apply,
  # so this is a deliberate second pass: apply, add the A record, set
  # lb_hostname, apply again. Empty means the annotation is simply absent.
  ingress_nginx_hostname_set = var.lb_hostname == "" ? [] : [
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/do-loadbalancer-hostname"
      value = var.lb_hostname
    },
  ]
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true

  # Blocks until DigitalOcean has provisioned the load balancer and assigned an
  # IP, so the data source below reads a populated status. DO routinely takes
  # five minutes or more over this, hence the generous timeout.
  wait    = true
  timeout = 900

  set = concat(local.ingress_nginx_set, local.ingress_nginx_hostname_set)
}

# Controller and CRDs only - no ClusterIssuer.
#
# This is the one deliberate difference from the marketplace stack, which ships a
# cluster-issuers chart. The LogiTrack chart creates its own *namespaced* Issuer
# (helm/logitrack/templates/certificate.yaml -> kind: Issuer, name
# logitrack-issuer) in its release namespace, with an ACME HTTP-01 solver pinned
# to ingressClassName: nginx. A ClusterIssuer here would go unused and would
# register a second ACME account against the same email.
#
# Terraform's job ends at: the CRDs are established and the controller is running.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  # wait matters here: the application chart's Issuer fails with "no matches for
  # kind Issuer" if helm runs before the CRDs are established.
  wait    = true
  timeout = 900

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    },
  ]
}

# Read after the release is ready, so status.loadBalancer is populated. The
# depends_on is load-bearing, not decoration: without it Terraform reads this
# during plan, before the cluster exists, against an unconfigured provider.
data "kubernetes_service_v1" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = helm_release.ingress_nginx.namespace
  }

  depends_on = [helm_release.ingress_nginx]
}

locals {
  ingress_ip = data.kubernetes_service_v1.ingress_nginx.status[0].load_balancer[0].ingress[0].ip
}
