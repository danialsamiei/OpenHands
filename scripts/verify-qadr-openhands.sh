#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.qadr}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

OPENHANDS_PORT="${OPENHANDS_PORT:-39030}"
PUBLIC_URL="${OH_WEB_URL:-https://hands.gantor.ir}"

wait_for_url() {
  local url="$1"
  local attempts="${2:-20}"
  local delay="${3:-3}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "$url" >/dev/null; then
      return 0
    fi
    sleep "$delay"
  done

  curl -fsS "$url" >/dev/null
}

echo "[1/5] Local health"
wait_for_url "http://127.0.0.1:${OPENHANDS_PORT}/health"
curl -fsS "http://127.0.0.1:${OPENHANDS_PORT}/health"
echo

echo "[2/5] Local auth surface"
curl -fsS "http://127.0.0.1:${OPENHANDS_PORT}/auth/login" >/dev/null
local_settings_status="$(curl -sS -o /tmp/qadr-openhands-local-settings.json -w '%{http_code}' "http://127.0.0.1:${OPENHANDS_PORT}/api/settings")"
echo "$local_settings_status"
cat /tmp/qadr-openhands-local-settings.json
echo

echo "[3/5] Public health"
wait_for_url "${PUBLIC_URL}/health"
curl -fsS "${PUBLIC_URL}/health"
echo

echo "[4/5] Public auth session expectation"
auth_status="$(curl -sS -o /tmp/qadr-openhands-auth.json -w '%{http_code}' "${PUBLIC_URL}/auth/session")"
echo "$auth_status"
cat /tmp/qadr-openhands-auth.json
echo

echo "[5/5] Public root headers"
curl -sSI "${PUBLIC_URL}/"
