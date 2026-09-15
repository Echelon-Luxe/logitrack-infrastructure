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

## Secrets

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
