#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.qadr}"
ENV_EXAMPLE="$ROOT_DIR/.env.qadr.example"
CONFIG_EXAMPLE="$ROOT_DIR/config.qadr.example.toml"
DEPLOY_SNIPPET="$ROOT_DIR/deploy/qadr-hands.caddyfile"

QADR_OPENHANDS_WORKDIR="${QADR_OPENHANDS_WORKDIR:-$ROOT_DIR}"
QADR_INGRESS_WORKDIR="${QADR_INGRESS_WORKDIR:-/home/saman/workspaces/freegpt/stacks/ingress-core}"
QADR_INGRESS_CADDYFILE="${QADR_INGRESS_CADDYFILE:-$QADR_INGRESS_WORKDIR/Caddyfile}"
QADR_INGRESS_COMPOSE="${QADR_INGRESS_COMPOSE:-$QADR_INGRESS_WORKDIR/compose.yaml}"

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  sed -i 's/\r$//' "$ENV_FILE"
}

upsert_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

ensure_session_secret() {
  local current
  current="$(grep -E '^FREEGPT_OPENHANDS_SESSION_SECRET=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  if [[ -z "$current" || "$current" == "REPLACE_WITH_LONG_RANDOM_SECRET" ]]; then
    upsert_env "FREEGPT_OPENHANDS_SESSION_SECRET" "$(generate_secret)"
  fi
}

ensure_qadr_defaults() {
  upsert_env "SANDBOX_CONTAINER_URL_PATTERN" "${SANDBOX_CONTAINER_URL_PATTERN:-https://hands.gantor.ir/runtime/{port}}"
  upsert_env "SANDBOX_INTERNAL_CONTAINER_URL_PATTERN" "${SANDBOX_INTERNAL_CONTAINER_URL_PATTERN:-http://host.docker.internal:{port}}"
  upsert_env "OH_WEB_URL" "${OH_WEB_URL:-https://hands.gantor.ir}"
  upsert_env "OH_PERMITTED_CORS_ORIGINS_0" "${OH_PERMITTED_CORS_ORIGINS_0:-https://hands.gantor.ir}"
  upsert_env "WEB_HOST" "${WEB_HOST:-hands.gantor.ir}"
  upsert_env "OPENHANDS_CONFIG_CLS" "${OPENHANDS_CONFIG_CLS:-openhands.qadr.server_config.QadrServerConfig}"
  upsert_env "FREEGPT_OPENHANDS_REQUIRE_LOGIN" "${FREEGPT_OPENHANDS_REQUIRE_LOGIN:-true}"
  upsert_env "FREEGPT_AUTH_BASE_URL" "${FREEGPT_AUTH_BASE_URL:-http://qadr-openwebui-app:8080}"
  upsert_env "FREEGPT_OPENHANDS_DEFAULT_LANGUAGE" "${FREEGPT_OPENHANDS_DEFAULT_LANGUAGE:-fa}"
  upsert_env "HIDE_LLM_SETTINGS" "${HIDE_LLM_SETTINGS:-true}"
  upsert_env "AUTH_URL" "${AUTH_URL:-https://hands.gantor.ir/auth/login}"
}

ensure_host_paths() {
  local state_dir workspace_dir
  state_dir="$(grep -E '^OPENHANDS_STATE_DIR=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')"
  workspace_dir="$(grep -E '^OPENHANDS_WORKSPACE_DIR=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')"
  mkdir -p "$state_dir" "$workspace_dir"
  if [[ ! -f "$state_dir/config.toml" ]]; then
    cp "$CONFIG_EXAMPLE" "$state_dir/config.toml"
  fi
}

patch_ingress_caddy() {
  python3 - "$QADR_INGRESS_CADDYFILE" "$DEPLOY_SNIPPET" <<'PY'
from pathlib import Path
import sys

caddyfile_path = Path(sys.argv[1])
snippet_path = Path(sys.argv[2])
snippet = snippet_path.read_text(encoding="utf-8").rstrip() + "\n"
text = caddyfile_path.read_text(encoding="utf-8")
lines = text.splitlines()
start = None
depth = 0
end = None
for idx, line in enumerate(lines):
    if start is None and line.strip() == "hands.gantor.ir {":
        start = idx
        depth = line.count("{") - line.count("}")
        continue
    if start is not None:
        depth += line.count("{") - line.count("}")
        if depth == 0:
            end = idx
            break

if start is None or end is None:
    new_text = text.rstrip() + "\n\n" + snippet
else:
    replacement = snippet.splitlines()
    lines[start : end + 1] = replacement
    new_text = "\n".join(lines).rstrip() + "\n"

if new_text != text:
    caddyfile_path.write_text(new_text, encoding="utf-8")
PY
}

patch_ingress_compose() {
  python3 - "$QADR_INGRESS_COMPOSE" <<'PY'
from pathlib import Path
import sys

compose_path = Path(sys.argv[1])
text = compose_path.read_text(encoding="utf-8")
if 'host.docker.internal:host-gateway' in text:
    raise SystemExit(0)

lines = text.splitlines()
start = None
end = None
for idx, line in enumerate(lines):
    if line.startswith("  caddy:"):
        start = idx
        continue
    if start is not None and line.startswith("  ") and not line.startswith("    "):
        end = idx
        break

if start is None:
    raise SystemExit("Could not find caddy service in ingress compose file")
if end is None:
    end = len(lines)

insert_at = None
for idx in range(start + 1, end):
    if lines[idx].startswith("    volumes:") or lines[idx].startswith("    networks:"):
        insert_at = idx
        break

if insert_at is None:
    insert_at = end

lines[insert_at:insert_at] = [
    "    extra_hosts:",
    '      - "host.docker.internal:host-gateway"',
]
compose_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

deploy_openhands() {
  cd "$QADR_OPENHANDS_WORKDIR"
  docker compose --env-file "$ENV_FILE" -f compose.qadr.yaml up -d --build
}

reload_ingress() {
  (
    cd "$QADR_INGRESS_WORKDIR"
    docker compose -f "$QADR_INGRESS_COMPOSE" up -d caddy
    docker exec qadr-ingress-core-caddy caddy reload --config /etc/caddy/Caddyfile
  )
}

main() {
  ensure_env_file
  ensure_session_secret
  ensure_qadr_defaults
  ensure_host_paths
  patch_ingress_caddy
  patch_ingress_compose
  deploy_openhands
  reload_ingress
  bash "$ROOT_DIR/scripts/verify-qadr-openhands.sh"
}

main "$@"
