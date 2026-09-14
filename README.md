# logitrack-infrastructure

Terraform, Helm charts, environment values and ArgoCD configuration for the LogiTrack platform.

**Contains no application source code.** Application repositories build and publish images;
this repository decides which image tag runs in which environment. That separation is what
makes the GitOps flow meaningful - every deployment is a reviewable, revertible commit here.