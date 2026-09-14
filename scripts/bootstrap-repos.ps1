<#
.SYNOPSIS
  Scaffolds the 7 LogiTrack application repositories with their baseline files.

.DESCRIPTION
  Idempotent: safe to re-run. Generates governance files (CODEOWNERS, .gitignore),
  a minimal buildable Fastify service exposing /healthz, /readyz and /metrics, a
  smoke test, and a CI workflow.

  WHY a runnable service in Phase 2 rather than Phase 3:
  branch protection can only *require* status checks that have actually reported at
  least once. A repo with no green CI run has nothing to require, so the protection
  rules silently protect nothing. A minimal service that genuinely lints, tests and
  builds gives the gates something real to enforce from day one.

.PARAMETER Root
  Parent directory holding the repo folders.
#>
param(
    [string]$Root = "C:\Users\USER\Desktop\SoundWhale\logitrack",
    # GitHub organisation that owns the repositories.
    [string]$Owner = "Echelon-Luxe",
    # CODEOWNERS principal. An org team (@Echelon-Luxe/platform) is the enterprise
    # pattern, but GitHub SILENTLY IGNORES owners that don't exist or lack write
    # access - turning the gate into decoration. Start with a real user; swap to a
    # team once the team exists and has been granted write.
    [string]$CodeOwner = "@dollarsmoney"
)

# GHCR normalises namespaces to lowercase; ghcr.io/Echelon-Luxe/... will not resolve.
$Registry = "ghcr.io/$($Owner.ToLowerInvariant())"

$ErrorActionPreference = 'Stop'

# service name -> @{ Port; Desc; Role }
$services = [ordered]@{
    'logitrack-api-gateway'          = @{ Port = 8080; Desc = 'Single entry point. Routes /api/* to backend services, verifies JWTs, enforces Redis-backed rate limits.'; Role = 'gateway' }
    'logitrack-user-service'         = @{ Port = 3001; Desc = 'Owns usersdb. Customer/driver/admin accounts, authentication, roles, JWT issuance.'; Role = 'api' }
    'logitrack-shipment-service'     = @{ Port = 3002; Desc = 'Owns shipmentsdb. Shipment lifecycle state machine. Sole producer of shipment.* events.'; Role = 'producer' }
    'logitrack-driver-service'       = @{ Port = 3003; Desc = 'Owns driversdb. Driver profiles and availability. Consumes shipment.assigned / shipment.delivered.'; Role = 'hybrid' }
    'logitrack-tracking-service'     = @{ Port = 3004; Desc = 'Owns trackingdb. Append-only tracking timeline built by consuming shipment.* events.'; Role = 'consumer' }
    'logitrack-notification-service' = @{ Port = 3005; Desc = 'Owns notificationsdb. Consumes shipment.* events and records simulated email notifications.'; Role = 'consumer' }
}

# ---------------------------------------------------------------- templates ---

$gitignore = @'
node_modules/
dist/
coverage/
*.tsbuildinfo

.env
.env.*
!.env.example

npm-debug.log*
.DS_Store
Thumbs.db

.vscode/
.idea/
'@

$gitattributes = @'
# Normalise to LF in the repository regardless of checkout platform.
# Windows-authored CRLF files break shell scripts inside Linux containers and
# produce spurious whole-file diffs when CI checks out on ubuntu-latest.
* text=auto eol=lf

*.ps1 text eol=crlf
*.png  binary
*.jpg  binary
*.ico  binary
*.woff2 binary
'@

$dockerignore = @'
node_modules
dist
coverage
test
.git
.github
.env
.env.*
*.md
!README.md
.vscode
.idea
'@

$codeowners = @'
# Every file requires review from the repo owner by default.
# On staging and production branches this is ENFORCED via
# require_code_owner_reviews, so this file is a real gate, not documentation.

*                       @OWNER

# Delivery machinery gets stricter treatment than application code:
# a broken workflow silently disables every security gate downstream.
/.github/workflows/     @OWNER
/Dockerfile             @OWNER
'@

$tsconfig = @'
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2023"],
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "exactOptionalPropertyTypes": true,
    "sourceMap": true,
    "declaration": false,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "test"]
}
'@

$packageJson = @'
{
  "name": "@SERVICE@",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=24" },
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc -p tsconfig.json",
    "start": "node dist/index.js",
    "lint": "eslint src test --max-warnings 0",
    "typecheck": "tsc --noEmit",
    "test": "vitest run --coverage"
  },
  "dependencies": {
    "fastify": "^5.2.0",
    "pino": "^9.6.0",
    "prom-client": "^15.1.3"
  },
  "devDependencies": {
    "@types/node": "^24.0.0",
    "@vitest/coverage-v8": "^2.1.8",
    "eslint": "^9.17.0",
    "tsx": "^4.19.2",
    "typescript": "^5.7.2",
    "typescript-eslint": "^8.18.0",
    "vitest": "^2.1.8"
  }
}
'@

$eslintConfig = @'
// @ts-check
import tseslint from 'typescript-eslint';

export default tseslint.config(
  ...tseslint.configs.recommended,
  {
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      'no-console': 'error', // structured logging via pino only
    },
  },
  { ignores: ['dist/**', 'coverage/**'] },
);
'@

$appTs = @'
import Fastify, { type FastifyInstance } from 'fastify';
import { Registry, collectDefaultMetrics, Counter } from 'prom-client';

export const SERVICE_NAME = '@SERVICE@';

/**
 * Readiness is deliberately separate from liveness.
 *
 *   /healthz (liveness)  -> "the process is not wedged". Failing this gets the
 *                           container KILLED, so it must never depend on
 *                           Postgres or Kafka. A DB outage restarting every pod
 *                           in a crash loop is a classic self-inflicted outage.
 *
 *   /readyz  (readiness) -> "this pod can serve traffic right now". Failing this
 *                           only removes the pod from the Service endpoints.
 *                           THIS is where dependency checks belong.
 */
let ready = false;
export const setReady = (v: boolean): void => { ready = v; };

export function buildApp(): FastifyInstance {
  const registry = new Registry();
  registry.setDefaultLabels({ service: SERVICE_NAME });
  collectDefaultMetrics({ register: registry });

  const httpRequests = new Counter({
    name: 'http_requests_total',
    help: 'Total HTTP requests',
    labelNames: ['method', 'route', 'status'] as const,
    registers: [registry],
  });

  const app = Fastify({
    // Structured JSON logs to stdout. Never log to files in a container -
    // the collector (Promtail/Fluent Bit) reads stdout, and a file inside an
    // ephemeral filesystem is lost the moment the pod is rescheduled.
    logger: { level: process.env['LOG_LEVEL'] ?? 'info' },
    // Trust the ingress controller's X-Forwarded-* headers so client IPs
    // (used for rate limiting) are real rather than the ingress pod's IP.
    trustProxy: true,
  });

  app.addHook('onResponse', (req, reply, done) => {
    httpRequests.inc({
      method: req.method,
      route: req.routeOptions.url ?? 'unknown',
      status: String(reply.statusCode),
    });
    done();
  });

  app.get('/healthz', () => ({ status: 'ok', service: SERVICE_NAME }));

  app.get('/readyz', async (_req, reply) => {
    if (!ready) return reply.code(503).send({ status: 'not-ready', service: SERVICE_NAME });
    return { status: 'ready', service: SERVICE_NAME };
  });

  app.get('/metrics', async (_req, reply) => {
    reply.header('Content-Type', registry.contentType);
    return registry.metrics();
  });

  return app;
}
'@

$indexTs = @'
import { buildApp, setReady, SERVICE_NAME } from './app.js';

const PORT = Number(process.env['PORT'] ?? @PORT@);
const app = buildApp();

async function main(): Promise<void> {
  await app.listen({ port: PORT, host: '0.0.0.0' });
  // Phase 3 replaces this with real dependency checks (Postgres, Kafka, Redis).
  setReady(true);
  app.log.info({ service: SERVICE_NAME, port: PORT }, 'service started');
}

/**
 * Graceful termination. Kubernetes sends SIGTERM, waits terminationGracePeriodSeconds,
 * then SIGKILLs. Without this handler in-flight requests are severed mid-response and
 * every rolling update produces 502s that look like an application bug.
 */
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    app.log.info({ signal }, 'shutting down');
    // Fail readiness first so the endpoint controller pulls this pod out of
    // rotation BEFORE we stop accepting connections.
    setReady(false);
    void app.close().then(() => process.exit(0));
  });
}

main().catch((err: unknown) => {
  app.log.error({ err }, 'failed to start');
  process.exit(1);
});
'@

$testTs = @'
import { describe, it, expect, afterEach } from 'vitest';
import { buildApp, setReady } from '../src/app.js';

describe('health endpoints', () => {
  afterEach(() => setReady(false));

  it('liveness is up even before dependencies are ready', async () => {
    const app = buildApp();
    const res = await app.inject({ method: 'GET', url: '/healthz' });
    expect(res.statusCode).toBe(200);
    await app.close();
  });

  it('readiness returns 503 until the service marks itself ready', async () => {
    const app = buildApp();
    const res = await app.inject({ method: 'GET', url: '/readyz' });
    expect(res.statusCode).toBe(503);
    await app.close();
  });

  it('readiness returns 200 once ready', async () => {
    const app = buildApp();
    setReady(true);
    const res = await app.inject({ method: 'GET', url: '/readyz' });
    expect(res.statusCode).toBe(200);
    await app.close();
  });

  it('exposes prometheus metrics', async () => {
    const app = buildApp();
    const res = await app.inject({ method: 'GET', url: '/metrics' });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain('process_cpu_user_seconds_total');
    await app.close();
  });
});
'@

# Actions are pinned to full commit SHAs. A tag like @v4 is MUTABLE - whoever controls
# the repo can repoint it at new code, which is exactly how the tj-actions/changed-files
# supply-chain compromise leaked secrets from thousands of pipelines. The version comment
# is for humans; the SHA is what actually runs.
$ciWorkflow = @'
name: CI

on:
  pull_request:
    branches: [dev, staging, production]
  push:
    branches: [dev]

# Least privilege by default. Jobs that need more must ask for it explicitly.
permissions:
  contents: read

# A new push to the same PR cancels the superseded run instead of burning
# runner minutes on a commit nobody will merge.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  NODE_VERSION: '24'

jobs:
  # ---------------------------------------------------------------- quality ---
  quality:
    name: lint / typecheck / test / build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: npm

      # `npm ci` (not `npm install`) - installs exactly the lockfile, fails if
      # package.json and the lockfile disagree. Reproducible by construction.
      - name: Install dependencies
        run: npm ci

      - name: Lint
        run: npm run lint

      - name: Typecheck
        run: npm run typecheck

      - name: Test
        run: npm test

      - name: Build
        run: npm run build

  # ------------------------------------------------------- secret scanning ---
  secrets:
    name: secret scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          # Gitleaks scans HISTORY, not just the working tree. A secret that was
          # committed and then "removed" in a later commit is still in the pack
          # files and still compromised. Depth 0 fetches the full history.
          fetch-depth: 0

      # The gitleaks ACTION requires a paid licence for organisation accounts.
      # The binary is MIT-licensed and free, so we pin and run it directly.
      - name: Install gitleaks
        run: |
          VERSION=8.24.0
          curl -sSfL -o /tmp/gitleaks.tar.gz \
            "https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/gitleaks_${VERSION}_linux_x64.tar.gz"
          tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks
          sudo mv /tmp/gitleaks /usr/local/bin/

      # No continue-on-error. A leaked credential must block the merge.
      - name: Scan for secrets
        run: gitleaks detect --source . --redact --verbose --exit-code 1

  # --------------------------------------------------- dependency scanning ---
  dependencies:
    name: dependency audit
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: npm

      - name: Install dependencies
        run: npm ci

      # Fails on high and critical. Moderate and below are reported but do not
      # block - otherwise a transitive advisory in a dev-only dependency stops
      # all delivery, and the team learns to ignore the gate entirely.
      - name: Audit dependencies
        run: npm audit --audit-level=high
'@

$readme = @'
# @SERVICE@

@DESC@

Part of the [LogiTrack](https://github.com/@OWNER@) platform. See
[logitrack-infrastructure](https://github.com/@OWNER@/logitrack-infrastructure)
for deployment, Helm charts and the ArgoCD configuration.

## Endpoints

| Path | Purpose |
|---|---|
| `GET /healthz` | Liveness. Never checks dependencies - failing it kills the container. |
| `GET /readyz` | Readiness. Checks dependencies - failing it only removes the pod from the Service. |
| `GET /metrics` | Prometheus exposition. |

## Local development

```bash
npm ci
npm run dev        # tsx watch, listens on @PORT@
npm test           # vitest + coverage
npm run lint       # eslint, zero warnings tolerated
npm run typecheck  # tsc --noEmit
```

## Branches

`dev` (default) -> `staging` -> `production`. Never commit directly to any of them;
open a PR from `feature/*`, `bugfix/*` or `hotfix/*`. See CONTRIBUTING.md in the
infrastructure repo.

## Images

Built by CI on GitHub runners and pushed to
`@REGISTRY@/@SERVICE@:<git-sha>`.
The image tag deployed to each environment is controlled by the infrastructure
repository, not by this one.
'@

# ---------------------------------------------------------------- generation ---

function Write-File([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # UTF8 without BOM - a BOM breaks shebangs, YAML parsers and some linters
    [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

foreach ($name in $services.Keys) {
    $meta = $services[$name]
    $repo = Join-Path $Root $name

    $expand = {
        param($t)
        $t.Replace('@SERVICE@', $name).
           Replace('@PORT@', [string]$meta.Port).
           Replace('@DESC@', $meta.Desc).
           Replace('@REGISTRY@', $Registry).
           Replace('@OWNER@', $Owner)
    }

    Write-File "$repo\.gitignore"       $gitignore
    Write-File "$repo\.gitattributes"   $gitattributes
    Write-File "$repo\.dockerignore"    $dockerignore
    Write-File "$repo\CODEOWNERS"       ($codeowners.Replace('@OWNER', $CodeOwner))
    Write-File "$repo\tsconfig.json"    $tsconfig
    Write-File "$repo\eslint.config.js" $eslintConfig
    Write-File "$repo\package.json"     (& $expand $packageJson)
    Write-File "$repo\src\app.ts"       (& $expand $appTs)
    Write-File "$repo\src\index.ts"     (& $expand $indexTs)
    Write-File "$repo\test\health.test.ts" $testTs
    Write-File "$repo\README.md"        (& $expand $readme)
    Write-File "$repo\.github\workflows\ci.yml" $ciWorkflow

    Write-Host "scaffolded $name (port $($meta.Port))"
}

Write-Host "`nDone. $($services.Count) services scaffolded under $Root"
