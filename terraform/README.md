# logitrack-terraform

Provisions the DigitalOcean Kubernetes cluster the LogiTrack Helm chart deploys onto:
`dev-cluster` in `lon1`, ingress-nginx, cert-manager, the `logitrack-dev` namespace and a GHCR
image pull secret.

**This directory is intentionally outside every git repository.** `logitrack-infrastructure` is
pushed to GitHub; this is not. Do not `git init` here, do not copy it into the infra repo.

Terraform stops at the platform. It does **not** run the chart — that stays a `helm upgrade` you
drive, so a bad release never blocks a `terraform apply`.

## What it creates

| Resource | Notes |
|---|---|
| `digitalocean_vpc` | `dev-cluster-vpc`, its own network so destroy reclaims everything |
| `digitalocean_kubernetes_cluster` | `dev-cluster`, 2 × `s-2vcpu-4gb`, autoscale 2–4, auto-upgrade Sundays 03:00 |
| `helm_release.ingress_nginx` | chart 4.14.5, `LoadBalancer`, IngressClass named `nginx`, made default |
| `helm_release.cert_manager` | chart v1.17.1, CRDs enabled. **No ClusterIssuer** — see below |
| `kubernetes_namespace_v1.app` | `logitrack-dev`, PodSecurity `enforce=baseline` |
| `kubernetes_secret_v1.ghcr` | `ghcr-pull`, dockerconfigjson for private GHCR images |

### Why no ClusterIssuer

The chart creates its own **namespaced** `Issuer` (`helm/logitrack/templates/certificate.yaml` →
`kind: Issuer`, name `logitrack-issuer`) with an ACME HTTP-01 solver pinned to
`ingressClassName: nginx`, plus the `logitrack-tls` `Certificate`. A ClusterIssuer here would be
unused and would register a second ACME account on the same email. Terraform installs the
controller and the CRDs; the chart does the rest.

## Apply

```powershell
$env:DIGITALOCEAN_TOKEN = "dop_v1_..."
Copy-Item terraform.tfvars.example terraform.tfvars   # then fill in ghcr_username / ghcr_token

terraform init
terraform apply -target=digitalocean_kubernetes_cluster.main   # pass 1, ~6 min
terraform apply                                                # pass 2, ~10 min
```

**The first apply is targeted on purpose.** The `kubernetes` and `helm` providers are configured
from `digitalocean_kubernetes_cluster.main`, whose endpoint and token are unknown at plan time on
an empty account. Creating the cluster first makes those values known, so pass 2 configures both
providers cleanly. Terraform prints a "resource targeting is for exceptional circumstances"
warning on pass 1 — expected, not an error.

Then:

```powershell
terraform output ingress_ip
terraform output dns_records_to_create
doctl kubernetes cluster kubeconfig save dev-cluster
```

## DNS — do this before deploying the chart

`kmdndd.name.ng` currently **does not resolve at all**: every public resolver returns SERVFAIL, and
there is no zone for it in this DigitalOcean account. Find where its nameservers actually point
before creating anything:

```powershell
nslookup -type=NS kmdndd.name.ng 8.8.8.8
```

Then create, wherever that zone lives:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `dev` | `terraform output ingress_ip` | 300 |
| A | `@` | same IP | 300 |

Verify against a **public** resolver — Let's Encrypt validates from the internet, so a record that
only resolves locally is not enough:

```powershell
nslookup dev.kmdndd.name.ng 8.8.8.8
```

If you later delegate the domain to `ns1/ns2/ns3.digitalocean.com`, set `manage_dns = true` and
Terraform takes the zone over; `dns.tf` already has the resources.

## Deploy the chart

From `..\logitrack\logitrack-infrastructure`:

```powershell
helm upgrade --install logitrack .\helm\logitrack `
  --namespace logitrack-dev `
  -f .\helm\logitrack\values.yaml `
  -f .\helm\logitrack\values-doks.yaml `
  --wait --timeout 10m
```

Four things to know:

- **No `--create-namespace`.** Terraform owns `logitrack-dev`; Helm would adopt and annotate it and
  the next apply would fight over it.
- **`values-dev.yaml` is not layered in.** It pins `logitrack.local` and a `selfSigned` issuer,
  both of which `values-doks.yaml` exists to replace. Layer `values.yaml` then `values-doks.yaml`.
  That file now lives in the infra repo so CI can read it; it holds no secrets.
- **Image tags are pinned to SHAs in `helm/logitrack/values-doks.yaml`**, in the infra repo. The chart defaults every service to
  `image.tag: dev`, but CI only ever pushes full-SHA tags and no `dev` tag exists in GHCR — the
  defaults would be a guaranteed `ImagePullBackOff`. The pinned tags are the newest image per
  service as of 2026-09-17; the refresh command is in the file.
- **Staging certificates are untrusted.** `helm/logitrack/values-doks.yaml` points at Let's Encrypt staging, which
  issues from the "(STAGING) Pretend Pear" root, so browsers show an interstitial and `curl` needs
  `-k`. That is deliberate: production allows 5 duplicate certs per week and locks you out for 7
  days once exhausted. Switch `acme.server` to `https://acme-v02.api.letsencrypt.org/directory`
  only after staging issuance works, then
  `kubectl -n logitrack-dev delete secret logitrack-tls` to force reissue.

## Verify

```bash
kubectl get nodes -o wide                       # 2 Ready
kubectl get storageclass                        # do-block-storage (default)

kubectl get ingressclass                        # nginx, DEFAULT=true
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP == terraform output ingress_ip
curl -I http://<ingress_ip>                     # 404 from nginx = LB works, no Host matches yet

kubectl -n cert-manager get pods                # cert-manager, -webhook, -cainjector Running
kubectl get crd | grep cert-manager.io          # 6 CRDs
kubectl get clusterissuer                       # "No resources found" is CORRECT

kubectl get ns logitrack-dev --show-labels
kubectl -n logitrack-dev get secret ghcr-pull -o jsonpath='{.type}'   # kubernetes.io/dockerconfigjson
```

After DNS resolves and the chart is deployed:

```bash
kubectl -n logitrack-dev get pods               # ImagePullBackOff here = pull secret problem
kubectl -n logitrack-dev get ingress            # ADDRESS populated

# TLS, in dependency order - the first non-Ready one is where it is stuck
kubectl -n logitrack-dev get issuer logitrack-issuer      # Ready=True means ACME account registered
kubectl -n logitrack-dev get certificate logitrack-tls
kubectl -n logitrack-dev get certificaterequest,order,challenge
kubectl -n logitrack-dev describe challenge               # the real error lives here

curl -kvI https://dev.kmdndd.name.ng            # issuer: CN=(STAGING) ... Pretend Pear
```

`https://dev.kmdndd.name.ng/` serves the **API gateway**, not a UI — `logitrack-frontend` is not in
the chart's `services` map. `/healthz` is a good smoke test.

### When something is stuck

| Symptom | Cause |
|---|---|
| `Challenge` pending, self-check timeout | DOKS hairpin. Set `lb_hostname = "dev.kmdndd.name.ng"` and re-apply — see the comment in `platform.tf` |
| `Challenge` returns 404 or wrong host | DNS not propagated, or `ingress.host` not overridden |
| `Issuer` not Ready | bad or empty `certificates.issuer.acme.email` |
| `ImagePullBackOff`, "denied" | PAT lacks `read:packages`, expired, or the image tag does not exist |
| Pods Running but never Ready | expected today — see "Known gaps" |

## CI deploys

`rbac.tf` creates a `logitrack-deployer` ServiceAccount scoped to `logitrack-dev` only. Its
kubeconfig is what GitHub Actions uses — it cannot touch the cluster, other namespaces, or
DigitalOcean:

```powershell
terraform output -raw deployer_kubeconfig
```

Paste that into the **infrastructure** repo as the `KUBE_CONFIG` secret. The deploy pipeline
itself lives in `logitrack-infrastructure/.github/workflows/deploy.yml`.

## Known gaps in the chart

Neither is fixable from Terraform; both need a change in `logitrack-infrastructure`.

1. ~~`logitrack-secrets` is never mounted.~~ **Fixed** — `deployment.yaml` now has an optional
   `secretRef`. The Secret still has to be created in the cluster by hand (see below); until it
   is, pods start and fail their readiness DB check.
2. **`values-prod.yaml` omits `payment-service`** from its tag list, so it silently inherits
   `tag: dev`. Harmless for this dev cluster, a latent incident on promotion.

## Teardown

Order matters, or you pay for orphaned resources Terraform no longer tracks:

```powershell
helm uninstall logitrack -n logitrack-dev
kubectl -n logitrack-dev delete pvc --all        # block volumes outlive helm uninstall
terraform destroy -target=helm_release.ingress_nginx   # releases the DO load balancer
terraform destroy
```

## Cost

| Item | Monthly |
|---|---|
| 2 × `s-2vcpu-4gb` | ~$48 |
| DigitalOcean load balancer | ~$12 |
| DOKS control plane | free |
| **Total** | **~$60**, ~$108 if the autoscaler hits 4 nodes |

## Secrets, honestly

`terraform.tfstate` holds the GHCR PAT **in plaintext**, along with the cluster CA and an admin
token. `sensitive = true` only hides values from CLI output; it does not encrypt state. Since this
directory is not in git, the `.gitignore` here is a backstop, not the control. The real ones:

- Never `git init` here and never copy this folder into `logitrack-infrastructure`.
- Check the Desktop is not OneDrive-synced: `(Get-Item ~\Desktop).Target`.
- Scope the PAT to `read:packages` with an expiry, so a leaked state file means "someone can pull
  dev images", not "someone can push to your registry".
- `DIGITALOCEAN_TOKEN` stays an environment variable and never enters tfvars.
