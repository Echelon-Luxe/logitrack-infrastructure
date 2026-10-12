#!/usr/bin/env bash
# Run the whole platform on a Mac/Linux host against local Docker dependencies.
#
#   ./dev.sh setup     # env + infra + migrate + seed users (first run)
#   ./dev.sh up        # start all 8 processes in the background
#   ./dev.sh seed      # demo shipments, drivers, live locations (needs `up`)
#   ./dev.sh status    # health of every service
#   ./dev.sh logs user # tail one service's log
#   ./dev.sh down      # stop the processes (infra keeps running)
#   ./dev.sh nuke      # stop everything and drop the local databases
#
# The PowerShell scripts next to this one target Supabase on Windows; this one
# is fully offline. Existing .env files are backed up to .env.supabase.bak the
# first time `env` runs, never overwritten after that.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SECRETS="$HERE/.secrets"
LOGS="$HERE/logs"
PIDS="$HERE/.pids"
COMPOSE=(docker compose -f "$HERE/docker-compose.yml")

# name:port:db-suffix (db-suffix empty = no database)
SERVICES=(
  "user:3001:users"
  "shipment:3002:shipments"
  "driver:3003:drivers"
  "tracking:3004:tracking"
  "notification:3005:notifications"
  "payment:3006:payments"
)

dir_of() {
  case "$1" in
    gateway) echo "$ROOT/logitrack-api-gateway" ;;
    frontend) echo "$ROOT/logitrack-frontend" ;;
    *) echo "$ROOT/logitrack-$1-service" ;;
  esac
}

say() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }

ensure_secrets() {
  mkdir -p "$SECRETS"
  if [[ ! -f "$SECRETS/jwt-private.pem" ]]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SECRETS/jwt-private.pem" 2>/dev/null
    openssl pkey -in "$SECRETS/jwt-private.pem" -pubout -out "$SECRETS/jwt-public.pem"
    ok "generated a persistent RS256 key pair in local/.secrets"
  fi
  if [[ ! -f "$SECRETS/internal-token" ]]; then
    openssl rand -hex 32 > "$SECRETS/internal-token"
  fi
}

backup_env() {
  local dir="$1"
  if [[ -f "$dir/.env" && ! -f "$dir/.env.supabase.bak" ]]; then
    cp "$dir/.env" "$dir/.env.supabase.bak"
    warn "backed up $(basename "$dir")/.env -> .env.supabase.bak"
  fi
}

cmd_env() {
  ensure_secrets
  local internal; internal="$(cat "$SECRETS/internal-token")"
  local priv; priv="$(cat "$SECRETS/jwt-private.pem")"
  local pub; pub="$(cat "$SECRETS/jwt-public.pem")"

  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name port db <<<"$entry"
    local dir; dir="$(dir_of "$name")"
    backup_env "$dir"
    local url="postgresql://${db}_svc:${db}_svc@localhost:5432/${db}db"
    {
      echo "# Written by logitrack-infrastructure/local/dev.sh - local Docker Postgres."
      echo "DATABASE_URL=\"$url\""
      echo "DIRECT_URL=\"$url\""
      echo "KAFKA_BROKERS=\"localhost:9092\""
      echo "PORT=$port"
      echo "LOG_LEVEL=info"
      echo "SEQ_URL=\"http://localhost:5341\""
      echo "INTERNAL_TOKEN=\"$internal\""
      case "$name" in
        user)
          echo "JWT_PRIVATE_KEY=\"$priv\""
          echo "JWT_PUBLIC_KEY=\"$pub\""
          ;;
        shipment)
          echo "DRIVER_SERVICE_URL=\"http://localhost:3003\""
          ;;
        payment)
          echo "SHIPMENT_SERVICE_URL=\"http://localhost:3002\""
          if [[ -n "${PAYSTACK_SECRET_KEY:-}" ]]; then
            echo "PAYMENT_PROVIDER=paystack"
            echo "PAYSTACK_SECRET_KEY=\"$PAYSTACK_SECRET_KEY\""
          else
            # Mock provider: payments settle from the UI, no Paystack account needed.
            echo "PAYMENT_PROVIDER=mock"
            echo "PAYSTACK_SECRET_KEY=\"sk_test_local_mock\""
          fi
          echo "PAYSTACK_CALLBACK_URL=\"http://localhost:3000/payments/callback\""
          ;;
      esac
    } > "$dir/.env"
    ok "wrote $(basename "$dir")/.env"
  done

  local gw; gw="$(dir_of gateway)"
  backup_env "$gw"
  cat > "$gw/.env" <<EOF
# Written by logitrack-infrastructure/local/dev.sh
JWKS_URL="http://localhost:3001/.well-known/jwks.json"
USER_SERVICE_URL="http://localhost:3001"
SHIPMENT_SERVICE_URL="http://localhost:3002"
DRIVER_SERVICE_URL="http://localhost:3003"
TRACKING_SERVICE_URL="http://localhost:3004"
NOTIFICATION_SERVICE_URL="http://localhost:3005"
PAYMENT_SERVICE_URL="http://localhost:3006"
CORS_ORIGINS="http://localhost:3000"
INTERNAL_TOKEN="$internal"
RATE_LIMIT_MAX=600
RATE_LIMIT_WINDOW="1 minute"
PORT=8080
LOG_LEVEL=info
SEQ_URL="http://localhost:5341"
EOF
  ok "wrote logitrack-api-gateway/.env"

  cat > "$(dir_of frontend)/.env.local" <<EOF
# Written by logitrack-infrastructure/local/dev.sh
NEXT_PUBLIC_API_URL=http://localhost:8080/api
# Dev only: enables the one-click demo sign-in chips on the login page.
NEXT_PUBLIC_DEMO_PASSWORD=LogiTrack-demo-2026
EOF
  ok "wrote logitrack-frontend/.env.local"
}

cmd_infra() {
  say "starting postgres, redpanda and seq"
  "${COMPOSE[@]}" up -d --wait postgres redpanda seq
  # init-db.sql only runs on an empty volume; make roles that were added later.
  "${COMPOSE[@]}" exec -T postgres psql -U postgres -v ON_ERROR_STOP=0 -q >/dev/null 2>&1 <<'SQL' || true
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'payments_svc') THEN
    CREATE ROLE payments_svc WITH LOGIN PASSWORD 'payments_svc';
  END IF;
END $$;
SELECT 'CREATE DATABASE paymentsdb OWNER payments_svc'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'paymentsdb')\gexec
SQL
  for t in logitrack.shipment.events logitrack.payment.events; do
    "${COMPOSE[@]}" exec -T redpanda rpk topic create "$t" -p 3 >/dev/null 2>&1 || true
  done
  ok "infra ready (Seq UI: http://localhost:8081)"
}

cmd_migrate() {
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name _ _ <<<"$entry"
    local dir; dir="$(dir_of "$name")"
    say "migrating $name"
    (cd "$dir" && npx prisma migrate deploy >/dev/null && npx prisma generate >/dev/null)
    ok "$name migrated"
  done
}

cmd_seed_users() {
  say "seeding demo users"
  (cd "$(dir_of user)" && npx tsx --env-file=.env prisma/seed.ts)
}

cmd_seed() {
  node "$HERE/seed.mjs"
}

start_one() {
  local name="$1" dir; dir="$(dir_of "$name")"
  mkdir -p "$LOGS" "$PIDS"
  if [[ -f "$PIDS/$name" ]] && kill -0 "$(cat "$PIDS/$name")" 2>/dev/null; then
    warn "$name already running"
    return
  fi
  # setsid-less process group: `npm run dev` spawns tsx/next children, so the
  # whole group is killed on `down`.
  (cd "$dir" && exec nohup npm run dev >"$LOGS/$name.log" 2>&1) &
  echo $! > "$PIDS/$name"
  ok "started $name (log: local/logs/$name.log)"
}

cmd_up() {
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name _ _ <<<"$entry"
    start_one "$name"
  done
  sleep 3
  start_one gateway
  start_one frontend
  say "waiting for services"
  wait_ready
  cmd_status
  echo
  ok "open http://localhost:3000"
}

wait_ready() {
  for _ in $(seq 1 60); do
    if curl -fs localhost:8080/readyz >/dev/null 2>&1 && curl -fs localhost:3000/healthz >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  warn "timed out waiting; check ./dev.sh status and the logs"
}

kill_tree() {
  local pid="$1"
  local kids; kids="$(pgrep -P "$pid" || true)"
  for k in $kids; do kill_tree "$k"; done
  kill "$pid" 2>/dev/null || true
}

cmd_down() {
  [[ -d "$PIDS" ]] || { warn "nothing running"; return; }
  for f in "$PIDS"/*; do
    [[ -f "$f" ]] || continue
    kill_tree "$(cat "$f")"
    ok "stopped $(basename "$f")"
    rm -f "$f"
  done
}

cmd_status() {
  printf '%-14s %-6s %s\n' SERVICE PORT STATUS
  for entry in "${SERVICES[@]}" "gateway:8080:" "frontend:3000:"; do
    IFS=: read -r name port _ <<<"$entry"
    local path=/readyz; [[ "$name" == frontend ]] && path=/healthz
    if curl -fs "localhost:$port$path" >/dev/null 2>&1; then
      printf '%-14s %-6s \033[32mready\033[0m\n' "$name" "$port"
    else
      printf '%-14s %-6s \033[31mdown\033[0m\n' "$name" "$port"
    fi
  done
}

case "${1:-help}" in
  env) cmd_env ;;
  infra) cmd_infra ;;
  migrate) cmd_migrate ;;
  seed-users) cmd_seed_users ;;
  seed) cmd_seed ;;
  setup) cmd_env; cmd_infra; cmd_migrate; cmd_seed_users ;;
  up) cmd_up ;;
  down) cmd_down ;;
  restart) cmd_down; cmd_up ;;
  status) cmd_status ;;
  logs) tail -f "$LOGS/${2:?service name}.log" ;;
  nuke) cmd_down; "${COMPOSE[@]}" down -v ;;
  *) sed -n '2,13p' "$0" ;;
esac
