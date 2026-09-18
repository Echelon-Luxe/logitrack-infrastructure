# Local cluster

```powershell
kind create cluster --config local\kind-cluster.yaml

kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

kubectl create namespace logitrack-dev
kubectl create namespace logging

helm upgrade --install logging helm\logging -n logging
helm upgrade --install logitrack helm\logitrack -n logitrack-dev `
  -f helm\logitrack\values.yaml -f helm\logitrack\values-dev.yaml
```

Add to `C:\Windows\System32\drivers\etc\hosts`:

```
127.0.0.1 logitrack.local
127.0.0.1 logs.logitrack.local
```

Seq UI: http://logs.logitrack.local

## Logs without the cluster

For services run straight on the host (`npm run dev`), the Fluent Bit agent that
feeds Seq in the cluster is not there. Bring up Seq on its own and let each
service post to it:

```powershell
docker compose -f local\docker-compose.yml up -d seq
```

Seq UI: http://localhost:8081. Each service ships to it when `SEQ_URL` is set in
its `.env` (`setup-env.ps1` writes it); unset, it logs to stdout only. Never set
it on a pod - Fluent Bit already tails stdout there, so every line would land in
Seq twice.

## Secrets

Each service owns its own schema, so each needs its own connection string. One
shared DATABASE_URL points all seven at a single schema - which passes readiness,
because /readyz only runs SELECT 1, and then fails on the first real query.

```powershell
.\local\create-k8s-secrets.ps1   # pooler host read from the existing Secret
kubectl -n logitrack-dev rollout restart deployment
```

That creates `<service>-secrets` for all six database-backed services. The
shared Secret below carries what is genuinely common.


The chart expects a `logitrack-secrets` Secret in `logitrack-dev`. It is not
templated: putting values in a chart means putting them in git.

```powershell
kubectl create secret generic logitrack-secrets -n logitrack-dev `
  --from-literal=DATABASE_URL="..." `
  --from-literal=DIRECT_URL="..." `
  --from-literal=JWT_PRIVATE_KEY="..." `
  --from-literal=JWT_PUBLIC_KEY="..." `
  --from-literal=PAYSTACK_SECRET_KEY="..."
```
