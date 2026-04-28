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
  local internal_container_url_pattern="${SANDBOX_INTERNAL_CONTAINER_URL_PATTERN:-}"
  local desired_llm_model="${QADR_OPENHANDS_LLM_MODEL:-ollama/qwen2.5:3b}"
  local ollama_base_url="${QADR_OPENHANDS_OLLAMA_BASE_URL:-http://qadr-local-llm-ollama:11434}"
  local ollama_api_key="${QADR_OPENHANDS_OLLAMA_API_KEY:-ollama-local-placeholder}"
  local gateway_base_url="${QADR_OPENHANDS_GATEWAY_BASE_URL:-http://qadr-ai-gateway-litellm:4000/v1}"
  local gateway_api_key="${QADR_OPENHANDS_GATEWAY_API_KEY:-REPLACE_WITH_GATEWAY_SERVICE_KEY}"
  local gateway_custom_provider="${QADR_OPENHANDS_GATEWAY_CUSTOM_LLM_PROVIDER:-}"
  local effective_base_url="$gateway_base_url"
  local effective_api_key="$gateway_api_key"
  local effective_custom_provider="$gateway_custom_provider"
  if [[ -z "$internal_container_url_pattern" ]]; then
    internal_container_url_pattern='http://{sandbox_id}:8000'
  fi
  if [[ "$desired_llm_model" == ollama/* ]]; then
    effective_base_url="$ollama_base_url"
    effective_api_key="$ollama_api_key"
    effective_custom_provider=""
  fi
  upsert_env "AGENT_SERVER_BASE_IMAGE_REPOSITORY" "${AGENT_SERVER_BASE_IMAGE_REPOSITORY:-ghcr.io/openhands/agent-server}"
  upsert_env "AGENT_SERVER_BASE_IMAGE_TAG" "${AGENT_SERVER_BASE_IMAGE_TAG:-1.12.0-python}"
  upsert_env "AGENT_SERVER_IMAGE_REPOSITORY" "${AGENT_SERVER_IMAGE_REPOSITORY:-gantor/openhands-agent-server}"
  upsert_env "AGENT_SERVER_IMAGE_TAG" "${AGENT_SERVER_IMAGE_TAG:-qadr-pw}"
  upsert_env "SANDBOX_HOST_PORT" "${SANDBOX_HOST_PORT:-${OPENHANDS_PORT:-39030}}"
  upsert_env "SANDBOX_DOCKER_NETWORK" "${SANDBOX_DOCKER_NETWORK:-fgpt_ai}"
  upsert_env "SANDBOX_STARTUP_GRACE_SECONDS" "${SANDBOX_STARTUP_GRACE_SECONDS:-90}"
  upsert_env "SANDBOX_CONTAINER_URL_PATTERN" "${SANDBOX_CONTAINER_URL_PATTERN:-https://hands.gantor.ir/runtime/{port}}"
  upsert_env "SANDBOX_INTERNAL_CONTAINER_URL_PATTERN" "$internal_container_url_pattern"
  upsert_env "SANDBOX_WEBHOOK_BASE_URL" "${SANDBOX_WEBHOOK_BASE_URL:-http://qadr-openhands:3000/api/v1/webhooks}"
  upsert_env "OH_WEB_URL" "${OH_WEB_URL:-https://hands.gantor.ir}"
  upsert_env "OH_INTERNAL_MCP_URL" "${OH_INTERNAL_MCP_URL:-http://qadr-openhands:3000}"
  upsert_env "OH_PERMITTED_CORS_ORIGINS_0" "${OH_PERMITTED_CORS_ORIGINS_0:-https://hands.gantor.ir}"
  upsert_env "WEB_HOST" "${WEB_HOST:-hands.gantor.ir}"
  upsert_env "OPENHANDS_CONFIG_CLS" "${OPENHANDS_CONFIG_CLS:-openhands.qadr.server_config.QadrServerConfig}"
  upsert_env "FREEGPT_OPENHANDS_REQUIRE_LOGIN" "${FREEGPT_OPENHANDS_REQUIRE_LOGIN:-true}"
  upsert_env "FREEGPT_AUTH_BASE_URL" "${FREEGPT_AUTH_BASE_URL:-http://qadr-openwebui-app:8080}"
  upsert_env "FREEGPT_OPENHANDS_DEFAULT_LANGUAGE" "${FREEGPT_OPENHANDS_DEFAULT_LANGUAGE:-fa}"
  upsert_env "FREEGPT_OPENHANDS_ENFORCE_LLM_DEFAULTS" "${FREEGPT_OPENHANDS_ENFORCE_LLM_DEFAULTS:-true}"
  upsert_env "FREEGPT_OPENHANDS_INTERNAL_MCP_HOSTS" "${FREEGPT_OPENHANDS_INTERNAL_MCP_HOSTS:-qadr-openhands:3000,openhands:3000,host.docker.internal:${OPENHANDS_PORT:-39030},127.0.0.1:${OPENHANDS_PORT:-39030},localhost:${OPENHANDS_PORT:-39030}}"
  upsert_env "HIDE_LLM_SETTINGS" "${HIDE_LLM_SETTINGS:-true}"
  upsert_env "AUTH_URL" "${AUTH_URL:-https://hands.gantor.ir/auth/login}"
  upsert_env "QADR_OPENHANDS_LLM_MODEL" "$desired_llm_model"
  upsert_env "QADR_OPENHANDS_OLLAMA_BASE_URL" "$ollama_base_url"
  upsert_env "QADR_OPENHANDS_OLLAMA_API_KEY" "$ollama_api_key"
  upsert_env "QADR_OPENHANDS_GATEWAY_BASE_URL" "$gateway_base_url"
  upsert_env "QADR_OPENHANDS_GATEWAY_API_KEY" "$gateway_api_key"
  upsert_env "QADR_OPENHANDS_GATEWAY_CUSTOM_LLM_PROVIDER" "$gateway_custom_provider"
  upsert_env "QADR_OPENHANDS_EFFECTIVE_LLM_BASE_URL" "$effective_base_url"
  upsert_env "QADR_OPENHANDS_EFFECTIVE_LLM_API_KEY" "$effective_api_key"
  upsert_env "QADR_OPENHANDS_EFFECTIVE_LLM_CUSTOM_PROVIDER" "$effective_custom_provider"
  upsert_env "FREEGPT_OPENHANDS_INTERNAL_WEBHOOK_CIDRS" "${FREEGPT_OPENHANDS_INTERNAL_WEBHOOK_CIDRS:-172.19.0.0/16,127.0.0.1/32,::1/128}"
  upsert_env "FREEGPT_OPENHANDS_LOAD_PUBLIC_SKILLS" "${FREEGPT_OPENHANDS_LOAD_PUBLIC_SKILLS:-false}"
  upsert_env "FREEGPT_OPENHANDS_LOAD_USER_SKILLS" "${FREEGPT_OPENHANDS_LOAD_USER_SKILLS:-false}"
  upsert_env "FREEGPT_OPENHANDS_LOAD_PROJECT_SKILLS" "${FREEGPT_OPENHANDS_LOAD_PROJECT_SKILLS:-true}"
  upsert_env "FREEGPT_OPENHANDS_LOAD_ORG_SKILLS" "${FREEGPT_OPENHANDS_LOAD_ORG_SKILLS:-false}"
  upsert_env "QADR_OPENHANDS_LLM_TIMEOUT" "${QADR_OPENHANDS_LLM_TIMEOUT:-360}"
  upsert_env "QADR_OPENHANDS_LLM_MAX_MESSAGE_CHARS" "${QADR_OPENHANDS_LLM_MAX_MESSAGE_CHARS:-12000}"
  upsert_env "QADR_OPENHANDS_LLM_MAX_OUTPUT_TOKENS" "${QADR_OPENHANDS_LLM_MAX_OUTPUT_TOKENS:-1200}"
  upsert_env "QADR_OPENHANDS_LLM_NUM_RETRIES" "${QADR_OPENHANDS_LLM_NUM_RETRIES:-2}"
  upsert_env "QADR_OPENHANDS_LLM_RETRY_MIN_WAIT" "${QADR_OPENHANDS_LLM_RETRY_MIN_WAIT:-2}"
  upsert_env "QADR_OPENHANDS_LLM_RETRY_MAX_WAIT" "${QADR_OPENHANDS_LLM_RETRY_MAX_WAIT:-8}"
  upsert_env "QADR_OPENHANDS_LLM_RETRY_MULTIPLIER" "${QADR_OPENHANDS_LLM_RETRY_MULTIPLIER:-2}"
  upsert_env "QADR_OPENHANDS_LLM_TEMPERATURE" "${QADR_OPENHANDS_LLM_TEMPERATURE:-0.0}"
  upsert_env "QADR_OPENHANDS_LLM_CACHING_PROMPT" "${QADR_OPENHANDS_LLM_CACHING_PROMPT:-false}"
  upsert_env "QADR_OPENHANDS_LLM_NATIVE_TOOL_CALLING" "${QADR_OPENHANDS_LLM_NATIVE_TOOL_CALLING:-true}"
  upsert_env "QADR_OPENHANDS_LLM_DISABLE_STOP_WORD" "${QADR_OPENHANDS_LLM_DISABLE_STOP_WORD:-false}"
  upsert_env "QADR_OPENHANDS_LLM_REASONING_EFFORT" "${QADR_OPENHANDS_LLM_REASONING_EFFORT:-none}"
  upsert_env "QADR_OPENHANDS_LLM_ENABLE_ENCRYPTED_REASONING" "${QADR_OPENHANDS_LLM_ENABLE_ENCRYPTED_REASONING:-false}"
  upsert_env "QADR_OPENHANDS_LLM_EXTENDED_THINKING_BUDGET" "${QADR_OPENHANDS_LLM_EXTENDED_THINKING_BUDGET:-0}"
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

normalize_qadr_config() {
  local state_dir config_path
  local desired_llm_model
  local effective_base_url
  local effective_api_key
  local effective_custom_provider
  state_dir="$(grep -E '^OPENHANDS_STATE_DIR=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')"
  config_path="$state_dir/config.toml"
  desired_llm_model="$(grep -E '^QADR_OPENHANDS_LLM_MODEL=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
  effective_base_url="$(grep -E '^QADR_OPENHANDS_EFFECTIVE_LLM_BASE_URL=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
  effective_api_key="$(grep -E '^QADR_OPENHANDS_EFFECTIVE_LLM_API_KEY=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
  effective_custom_provider="$(grep -E '^QADR_OPENHANDS_EFFECTIVE_LLM_CUSTOM_PROVIDER=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
  python3 - "$config_path" "$desired_llm_model" "$effective_base_url" "$effective_api_key" "$effective_custom_provider" <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
desired_llm_model = sys.argv[2]
effective_base_url = sys.argv[3]
effective_api_key = sys.argv[4]
effective_custom_provider = sys.argv[5]
text = config_path.read_text(encoding="utf-8")

section_pattern = re.compile(r'(^\[llm\]\s*$)([\s\S]*?)(?=^\[|\Z)', re.MULTILINE)
match = section_pattern.search(text)
if not match:
    raise SystemExit(f"Missing [llm] section in {config_path}")

section_header = match.group(1)
section_body = match.group(2)

def set_or_remove(body: str, key: str, value: str | None) -> str:
    key_pattern = re.compile(rf'^{re.escape(key)}\s*=.*(?:\n|$)', re.MULTILINE)
    if value is None:
        return key_pattern.sub('', body)
    escaped = value.replace('\\', '\\\\').replace('"', '\\"')
    replacement = f'{key} = "{escaped}"\n'
    if key_pattern.search(body):
        return key_pattern.sub(replacement, body, count=1)
    return body + replacement

section_body = set_or_remove(section_body, "model", desired_llm_model)
section_body = set_or_remove(section_body, "base_url", effective_base_url or None)
section_body = set_or_remove(section_body, "api_key", effective_api_key or None)
if desired_llm_model.startswith("ollama/"):
    section_body = set_or_remove(section_body, "ollama_base_url", effective_base_url or None)
    section_body = set_or_remove(section_body, "custom_llm_provider", None)
else:
    section_body = set_or_remove(section_body, "ollama_base_url", None)
    section_body = set_or_remove(section_body, "custom_llm_provider", effective_custom_provider or None)

updated = text[:match.start()] + section_header + section_body + text[match.end():]

if updated != text:
    config_path.write_text(updated, encoding="utf-8")
PY
}

ensure_global_settings_defaults() {
  local state_dir
  local desired_llm_model
  local effective_base_url
  local effective_api_key
  local py_cmd=(python3)
  state_dir="$(grep -E '^OPENHANDS_STATE_DIR=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')"
  desired_llm_model="$(grep -E '^QADR_OPENHANDS_LLM_MODEL=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
  effective_base_url="$(grep -E '^QADR_OPENHANDS_EFFECTIVE_LLM_BASE_URL=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
  effective_api_key="$(grep -E '^QADR_OPENHANDS_EFFECTIVE_LLM_API_KEY=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
  if [[ -e "$state_dir/settings.json" ]]; then
    if [[ ! -w "$state_dir/settings.json" ]]; then
      py_cmd=(sudo -n python3)
    fi
  elif [[ ! -w "$state_dir" ]]; then
    py_cmd=(sudo -n python3)
  fi
  "${py_cmd[@]}" - "$state_dir/config.toml" "$state_dir/settings.json" "$desired_llm_model" "$effective_base_url" "$effective_api_key" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

config_path = Path(sys.argv[1])
settings_path = Path(sys.argv[2])
desired_llm_model = sys.argv[3]
effective_base_url = sys.argv[4]
effective_api_key = sys.argv[5]

if not config_path.exists():
    raise SystemExit(f"Missing config file: {config_path}")

config = tomllib.loads(config_path.read_text(encoding="utf-8"))
llm = config.get("llm") or {}

settings = {}
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        settings = {}

settings["language"] = settings.get("language") or "fa"
settings["v1_enabled"] = True
settings["llm_model"] = desired_llm_model
settings["llm_base_url"] = effective_base_url or llm.get("base_url") or settings.get("llm_base_url")
settings["llm_api_key"] = effective_api_key or llm.get("api_key") or None

settings_path.write_text(
    json.dumps(settings, ensure_ascii=False, separators=(",", ":")),
    encoding="utf-8",
)
PY
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

build_agent_server_image() {
  ENV_FILE="$ENV_FILE" bash "$ROOT_DIR/scripts/build-qadr-agent-server.sh"
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
  normalize_qadr_config
  ensure_global_settings_defaults
  build_agent_server_image
  patch_ingress_caddy
  patch_ingress_compose
  deploy_openhands
  reload_ingress
  VERIFY_PUBLIC_RESOLVE_ADDR="${VERIFY_PUBLIC_RESOLVE_ADDR:-127.0.0.1}" \
    bash "$ROOT_DIR/scripts/verify-qadr-openhands.sh"
}

main "$@"
