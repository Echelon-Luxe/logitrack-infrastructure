# ghcr.io/echelon-luxe/logitrack-* are private: CI pushes them with the
# workflow's GITHUB_TOKEN, and GHCR packages default to private. The chart ships
# `global.imagePullSecrets: []`, so without this secret every pod sits in
# ImagePullBackOff with "denied" - which reads like a missing tag rather than a
# missing credential.
#
# The token is a classic PAT with read:packages and nothing else. A token with
# write:packages here would let anything that can read this Secret overwrite the
# images it pulls.
#
# Pull secrets are namespaced. A second namespace needs its own copy.
resource "kubernetes_secret_v1" "ghcr" {
  metadata {
    name      = var.image_pull_secret_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  # `data` (not binary_data): the provider base64-encodes these values, which is
  # exactly what a .dockerconfigjson key needs.
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.ghcr_server) = {
          username = var.ghcr_username
          password = var.ghcr_token
          # Redundant with username/password for containerd, but some tooling
          # reads only this field. Cheap to include, expensive to debug.
          auth = base64encode("${var.ghcr_username}:${var.ghcr_token}")
        }
      }
    })
  }
}
