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
AGENT_SERVER_IMAGE_REPOSITORY="${AGENT_SERVER_IMAGE_REPOSITORY:-gantor/openhands-agent-server}"
AGENT_SERVER_IMAGE_TAG="${AGENT_SERVER_IMAGE_TAG:-qadr-pw}"
SANDBOX_DOCKER_NETWORK="${SANDBOX_DOCKER_NETWORK:-fgpt_ai}"
OH_INTERNAL_MCP_URL="${OH_INTERNAL_MCP_URL:-http://qadr-openhands:3000}"
VERIFY_PUBLIC_RESOLVE_ADDR="${VERIFY_PUBLIC_RESOLVE_ADDR:-}"
export PUBLIC_URL VERIFY_PUBLIC_RESOLVE_ADDR OH_WEB_URL FREEGPT_OPENHANDS_SESSION_SECRET FREEGPT_OPENHANDS_SESSION_COOKIE_NAME

PUBLIC_HOST="$(python3 - <<'PY'
import os
from urllib.parse import urlparse

parsed = urlparse(os.environ["PUBLIC_URL"])
print(parsed.hostname or "")
PY
)"

PUBLIC_PORT="$(python3 - <<'PY'
import os
from urllib.parse import urlparse

parsed = urlparse(os.environ["PUBLIC_URL"])
if parsed.port:
    print(parsed.port)
elif parsed.scheme == "http":
    print(80)
else:
    print(443)
PY
)"

public_curl() {
  if [[ -n "$VERIFY_PUBLIC_RESOLVE_ADDR" && -n "$PUBLIC_HOST" && -n "$PUBLIC_PORT" ]]; then
    curl --resolve "${PUBLIC_HOST}:${PUBLIC_PORT}:${VERIFY_PUBLIC_RESOLVE_ADDR}" "$@"
    return
  fi
  curl "$@"
}

wait_for_url() {
  local url="$1"
  local attempts="${2:-20}"
  local delay="${3:-3}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if public_curl -fsS "$url" >/dev/null; then
      return 0
    fi
    sleep "$delay"
  done

  public_curl -fsS "$url" >/dev/null
}

echo "[1/7] Local health"
wait_for_url "http://127.0.0.1:${OPENHANDS_PORT}/health"
curl -fsS "http://127.0.0.1:${OPENHANDS_PORT}/health"
echo

echo "[2/7] Local auth surface"
curl -fsS "http://127.0.0.1:${OPENHANDS_PORT}/auth/login" >/dev/null
local_settings_status="$(curl -sS -o /tmp/qadr-openhands-local-settings.json -w '%{http_code}' "http://127.0.0.1:${OPENHANDS_PORT}/api/settings")"
echo "$local_settings_status"
cat /tmp/qadr-openhands-local-settings.json
echo

echo "[3/7] Public health"
wait_for_url "${PUBLIC_URL}/health" 40 3
public_curl -fsS "${PUBLIC_URL}/health"
echo

echo "[4/7] Public auth session expectation"
auth_status="$(public_curl -sS -o /tmp/qadr-openhands-auth.json -w '%{http_code}' "${PUBLIC_URL}/auth/session")"
echo "$auth_status"
cat /tmp/qadr-openhands-auth.json
echo

echo "[5/7] Favicon should not be auth-blocked"
favicon_status="$(public_curl -sS -o /tmp/qadr-openhands-favicon.out -w '%{http_code}' "${PUBLIC_URL}/favicon.ico" || true)"
echo "$favicon_status"
if [[ "$favicon_status" == "401" ]]; then
  echo "favicon request is still auth-blocked" >&2
  exit 1
fi
echo

echo "[6/7] Public root headers"
public_curl -sSI "${PUBLIC_URL}/"
echo

echo "[7/11] Internal OpenHands health from sandbox network"
docker run --rm --network "${SANDBOX_DOCKER_NETWORK}" curlimages/curl:8.12.1 -fsS "${OH_INTERNAL_MCP_URL}/health"
echo

echo "[8/11] Internal MCP path should not redirect to login"
internal_mcp_status="$(
  docker run --rm --network "${SANDBOX_DOCKER_NETWORK}" curlimages/curl:8.12.1 \
    -sS -o /tmp/qadr-openhands-internal-mcp.out -w '%{http_code}' \
    -H 'X-OpenHands-ServerConversation-ID: deploy-smoke' \
    "${OH_INTERNAL_MCP_URL}/mcp/mcp" || true
)"
echo "$internal_mcp_status"
if [[ "$internal_mcp_status" == "302" || "$internal_mcp_status" == "401" || "$internal_mcp_status" == "403" ]]; then
  echo "internal MCP path is still auth-blocked" >&2
  exit 1
fi
echo

echo "[9/11] Agent-server browser smoke"
docker run --rm --entrypoint python3 "${AGENT_SERVER_IMAGE_REPOSITORY}:${AGENT_SERVER_IMAGE_TAG}" - <<'PY'
import asyncio
import playwright
from playwright.async_api import async_playwright

print(playwright.__file__)

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        await page.goto('https://example.com', wait_until='domcontentloaded', timeout=20000)
        print(await page.title())
        await browser.close()

asyncio.run(main())
PY

echo
echo "[10/11] Session-authenticated conversation smoke"
python3 - <<'PY'
import base64
import hashlib
import hmac
import json
import os
import socket
import time
from contextlib import contextmanager
from urllib.parse import urlparse

import requests

public_url = os.environ['OH_WEB_URL'].rstrip('/')
secret = os.environ['FREEGPT_OPENHANDS_SESSION_SECRET']
cookie_name = os.getenv('FREEGPT_OPENHANDS_SESSION_COOKIE_NAME', 'qadr_openhands_session')
llm_model = os.getenv('QADR_OPENHANDS_LLM_MODEL', 'ollama/qwen2.5:3b')
resolve_addr = os.getenv('VERIFY_PUBLIC_RESOLVE_ADDR', '').strip()
public_host = urlparse(public_url).hostname or ''

@contextmanager
def maybe_override_dns(hostname: str, resolved_ip: str):
    if not hostname or not resolved_ip:
        yield
        return

    original_getaddrinfo = socket.getaddrinfo

    def patched(host, port, family=0, type=0, proto=0, flags=0):
        if host == hostname:
            return original_getaddrinfo(resolved_ip, port, family, type, proto, flags)
        return original_getaddrinfo(host, port, family, type, proto, flags)

    socket.getaddrinfo = patched
    try:
        yield
    finally:
        socket.getaddrinfo = original_getaddrinfo

now = int(time.time())
payload = {
    'uid': 'deploy-smoke',
    'email': 'deploy-smoke@freegpt.local',
    'name': 'Deploy Smoke',
    'role': 'admin',
    'iat': now,
    'exp': now + 3600,
}
encoded = base64.urlsafe_b64encode(
    json.dumps(payload, ensure_ascii=True, separators=(',', ':'), sort_keys=True).encode('utf-8')
).decode('utf-8').rstrip('=')
signature = hmac.new(secret.encode('utf-8'), encoded.encode('utf-8'), hashlib.sha256).hexdigest()
cookie_value = f'{encoded}.{signature}'

session = requests.Session()
session.cookies.set(cookie_name, cookie_value, path='/', secure=True)

with maybe_override_dns(public_host, resolve_addr):
    auth_response = session.get(f'{public_url}/auth/session', timeout=30)
    auth_response.raise_for_status()
    auth_payload = auth_response.json()
    if not auth_payload.get('authenticated'):
        raise SystemExit(f'Authenticated session check failed: {auth_payload}')

    create_payload = {
        'title': 'Deploy Smoke',
        'llm_model': llm_model,
        'initial_message': {
            'content': [{'type': 'text', 'text': 'What is 17 + 8? Reply with the result only.'}],
            'run': True,
        },
    }
    create_response = session.post(
        f'{public_url}/api/v1/app-conversations',
        json=create_payload,
        timeout=60,
    )
    create_response.raise_for_status()
    task = create_response.json()
    task_id = task['id']

    status_payload = None
    for _ in range(48):
        time.sleep(5)
        poll_response = session.get(
            f'{public_url}/api/v1/app-conversations/start-tasks?ids={task_id}',
            timeout=30,
        )
        poll_response.raise_for_status()
        items = poll_response.json()
        status_payload = items[0] if items and items[0] else None
        if status_payload and status_payload.get('status') in {'READY', 'ERROR'}:
            break

    if not status_payload:
        raise SystemExit('Conversation smoke did not return any status payload')

    print(json.dumps(status_payload, ensure_ascii=False))
    if status_payload.get('status') != 'READY':
        raise SystemExit(f"Conversation smoke failed: {status_payload}")

    conversation_id = status_payload.get('app_conversation_id')
    if not conversation_id:
        raise SystemExit(f"Conversation smoke missing app_conversation_id: {status_payload}")

    events_payload = None
    for _ in range(18):
        time.sleep(5)
        events_response = session.get(
            f'{public_url}/api/v1/conversation/{conversation_id}/events/search',
            params={'limit': 100},
            timeout=30,
        )
        events_response.raise_for_status()
        events_payload = events_response.json()
        serialized_events = json.dumps(events_payload, ensure_ascii=False)
        if '"source": "assistant"' in serialized_events or 'Conversation run failed' in serialized_events:
            break

    print(json.dumps(events_payload, ensure_ascii=False)[:4000])
    serialized_events = json.dumps(events_payload, ensure_ascii=False)
    if 'LLM Provider NOT provided' in serialized_events:
        raise SystemExit('Conversation events still contain LiteLLM provider resolution failure')
    if 'key not allowed to access model' in serialized_events:
        raise SystemExit('Conversation events still contain an unauthorized gateway model')
    if '"25"' not in serialized_events and ' 25' not in serialized_events and '>25<' not in serialized_events:
        raise SystemExit('Conversation smoke did not capture the expected assistant output')
PY

echo
echo "[11/11] Browser-agent conversation smoke"
BROWSER_SMOKE_DIR="$(mktemp -d)"
BROWSER_SMOKE_PORT="${OPENHANDS_BROWSER_SMOKE_PORT:-39123}"
BROWSER_SMOKE_TOKEN="$(python3 - <<'PY'
import secrets
print(f"QADR-BROWSER-{secrets.token_hex(6)}")
PY
)"
cat >"${BROWSER_SMOKE_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>${BROWSER_SMOKE_TOKEN}</title>
  </head>
  <body>
    <main>
      <h1>${BROWSER_SMOKE_TOKEN}</h1>
      <p>This page is served from the QADR host for OpenHands browser smoke testing.</p>
    </main>
  </body>
</html>
EOF
python3 -m http.server "${BROWSER_SMOKE_PORT}" --bind 0.0.0.0 --directory "${BROWSER_SMOKE_DIR}" >/tmp/qadr-openhands-browser-smoke-server.log 2>&1 &
BROWSER_SMOKE_PID=$!
cleanup_browser_smoke() {
  if [[ -n "${BROWSER_SMOKE_PID:-}" ]]; then
    kill "${BROWSER_SMOKE_PID}" >/dev/null 2>&1 || true
    wait "${BROWSER_SMOKE_PID}" 2>/dev/null || true
  fi
  rm -rf "${BROWSER_SMOKE_DIR}"
}
trap cleanup_browser_smoke EXIT
sleep 1
curl -fsS "http://127.0.0.1:${BROWSER_SMOKE_PORT}/" >/dev/null
export BROWSER_SMOKE_TOKEN BROWSER_SMOKE_PORT
python3 - <<'PY'
import base64
import hashlib
import hmac
import json
import os
import socket
import time
from contextlib import contextmanager
from urllib.parse import urlparse

import requests

public_url = os.environ['OH_WEB_URL'].rstrip('/')
secret = os.environ['FREEGPT_OPENHANDS_SESSION_SECRET']
cookie_name = os.getenv('FREEGPT_OPENHANDS_SESSION_COOKIE_NAME', 'qadr_openhands_session')
llm_model = os.getenv('QADR_OPENHANDS_LLM_MODEL', 'ollama/qwen2.5:3b')
resolve_addr = os.getenv('VERIFY_PUBLIC_RESOLVE_ADDR', '').strip()
public_host = urlparse(public_url).hostname or ''
browser_smoke_token = os.environ['BROWSER_SMOKE_TOKEN']
browser_smoke_port = os.environ['BROWSER_SMOKE_PORT']

@contextmanager
def maybe_override_dns(hostname: str, resolved_ip: str):
    if not hostname or not resolved_ip:
        yield
        return

    original_getaddrinfo = socket.getaddrinfo

    def patched(host, port, family=0, type=0, proto=0, flags=0):
        if host == hostname:
            return original_getaddrinfo(resolved_ip, port, family, type, proto, flags)
        return original_getaddrinfo(host, port, family, type, proto, flags)

    socket.getaddrinfo = patched
    try:
        yield
    finally:
        socket.getaddrinfo = original_getaddrinfo

now = int(time.time())
payload = {
    'uid': 'deploy-browser-smoke',
    'email': 'deploy-browser-smoke@freegpt.local',
    'name': 'Deploy Browser Smoke',
    'role': 'admin',
    'iat': now,
    'exp': now + 3600,
}
encoded = base64.urlsafe_b64encode(
    json.dumps(payload, ensure_ascii=True, separators=(',', ':'), sort_keys=True).encode('utf-8')
).decode('utf-8').rstrip('=')
signature = hmac.new(secret.encode('utf-8'), encoded.encode('utf-8'), hashlib.sha256).hexdigest()
cookie_value = f'{encoded}.{signature}'

session = requests.Session()
session.cookies.set(cookie_name, cookie_value, path='/', secure=True)

prompt = (
    'Use the browser tool and do not answer from memory. '
    f'Open http://host.docker.internal:{browser_smoke_port}/, wait for the page to load, '
    'then reply with exactly TITLE=<page title>.'
)

with maybe_override_dns(public_host, resolve_addr):
    create_response = session.post(
        f'{public_url}/api/v1/app-conversations',
        json={
            'title': 'Deploy Browser Smoke',
            'llm_model': llm_model,
            'initial_message': {
                'content': [{'type': 'text', 'text': prompt}],
                'run': True,
            },
        },
        timeout=60,
    )
    create_response.raise_for_status()
    task = create_response.json()
    task_id = task['id']

    status_payload = None
    for _ in range(72):
        time.sleep(5)
        poll_response = session.get(
            f'{public_url}/api/v1/app-conversations/start-tasks?ids={task_id}',
            timeout=30,
        )
        poll_response.raise_for_status()
        items = poll_response.json()
        status_payload = items[0] if items and items[0] else None
        if status_payload and status_payload.get('status') in {'READY', 'ERROR'}:
            break

    if not status_payload or status_payload.get('status') != 'READY':
        raise SystemExit(f'Browser smoke failed before conversation start: {status_payload}')

    conversation_id = status_payload.get('app_conversation_id')
    if not conversation_id:
        raise SystemExit(f'Browser smoke missing app_conversation_id: {status_payload}')

    events_payload = None
    for _ in range(36):
        time.sleep(5)
        events_response = session.get(
            f'{public_url}/api/v1/conversation/{conversation_id}/events/search',
            params={'limit': 100},
            timeout=30,
        )
        events_response.raise_for_status()
        events_payload = events_response.json()
        serialized_events = json.dumps(events_payload, ensure_ascii=False)
        if f'TITLE={browser_smoke_token}' in serialized_events or 'BROWSER_TOOL_UNAVAILABLE' in serialized_events:
            break

    serialized_events = json.dumps(events_payload, ensure_ascii=False)
    print(serialized_events[:5000])
    if 'BROWSER_TOOL_UNAVAILABLE' in serialized_events:
        raise SystemExit('Browser smoke reported that browser tooling was unavailable')
    if f'TITLE={browser_smoke_token}' not in serialized_events:
        raise SystemExit('Browser smoke did not capture the expected browser-agent reply')
    if 'browser_' not in serialized_events and 'Browser' not in serialized_events:
        raise SystemExit('Browser smoke did not capture browser tool activity in the event stream')
PY
