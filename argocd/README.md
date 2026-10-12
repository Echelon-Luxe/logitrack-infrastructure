# Deploying to production

```
service repo: merge to dev
  └─ CI: test → build → scan → push ghcr.io/echelon-luxe/logitrack-<service>:<sha>
      └─ dispatch → promote.yml opens PR "Deploy <service> <sha> to production"
           └─ merge PR → Argo CD syncs logitrack-prod
```

- **Roll back:** revert the promotion PR on `production`.
- **Promote by hand:** Actions → promote → Run workflow, with a service and SHA.
- **Chart changes** go `dev` → `production` by PR like any other change. Don't
  edit `helm/logitrack/images-prod.yaml` on `dev`, or that merge will roll images back.

## One-time cluster setup

```bash
kubectl create namespace logitrack-prod

# GHCR pull secret: a PAT with read:packages only.
kubectl -n logitrack-prod create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<github-user> --docker-password=<PAT>

# App secrets - same keys as local/README.md, in logitrack-prod.
kubectl -n logitrack-prod create secret generic logitrack-secrets --from-literal=...
# plus <service>-secrets for each database-backed service

kubectl apply -f argocd/logitrack-prod.yaml
```

Argo CD UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443`, user `admin`,
password from the `argocd-initial-admin-secret` Secret.
