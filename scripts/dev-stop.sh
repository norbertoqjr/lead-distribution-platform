#!/usr/bin/env bash
# Stop everything `npm run dev` started: the web and api dev servers, then the
# database container. Safe to run from a second terminal while dev is running,
# and safe to run when nothing is up.
set -uo pipefail

cd "$(dirname "$0")/.."

[ -f .env ] && set -a && . ./.env && set +a

WEB_PORT="${WEB_PORT:-8192}"
API_PORT="${API_PORT:-8193}"

stop_port() {
  local name="$1" port="$2" pids
  pids=$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)

  if [ -z "$pids" ]; then
    echo "  ${name}: nothing listening on ${port}"
    return
  fi

  echo "  ${name}: stopping $(echo "$pids" | tr '\n' ' ')on ${port}"
  # SIGTERM first so Next.js and Nest can shut down cleanly.
  kill $pids 2>/dev/null || true

  for _ in $(seq 1 10); do
    sleep 0.5
    pids=$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true)
    [ -z "$pids" ] && break
  done

  if [ -n "$pids" ]; then
    echo "  ${name}: did not exit, forcing"
    kill -9 $pids 2>/dev/null || true
  fi
}

echo "Stopping dev servers..."
stop_port "web" "$WEB_PORT"
stop_port "api" "$API_PORT"

echo "Stopping database..."
# `stop`, not `down`: the container is preserved so the next start is fast.
# Data survives either way — it lives in a named volume.
docker compose stop

echo "Done."
