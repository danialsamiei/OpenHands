# QADR Deployment

This fork is prepared for a Persian-first deployment on `hands.gantor.ir`.

## Scope
- Public GUI for OpenHands on QADR
- Persian available in the UI language selector
- RTL-aware document language handling for Persian and Arabic
- Reverse proxy through the shared QADR Caddy ingress
- FreeGPT-backed login with signed session cookies
- Per-user isolation for settings, secrets, and conversations
- Runtime websocket proxying through `/runtime/{port}`
- Internal sandbox health checks through direct container DNS on `fgpt_ai`
- Internal sandbox-to-app callbacks through the shared Docker network `fgpt_ai`
- Internal MCP callbacks through `http://qadr-openhands:3000` so sandbox-side tool discovery does not depend on the public login wall
- Local custom agent-server image with Playwright baked into the sandbox runtime
- Default local-model path through direct `Ollama` on `qadr-local-llm-ollama:11434`
- Managed gateway fallback for external models such as `anthropic/claude-sonnet-4-20250514`
- Extended sandbox startup grace because the Playwright-enabled runtime takes longer to preload tools

## Files
- [`compose.qadr.yaml`](/C:/Users/never/Documents/CodeX/gantor-openhands/compose.qadr.yaml)
- [`.env.qadr.example`](/C:/Users/never/Documents/CodeX/gantor-openhands/.env.qadr.example)
- [`config.template.toml`](/C:/Users/never/Documents/CodeX/gantor-openhands/config.template.toml)
- [`config.qadr.example.toml`](/C:/Users/never/Documents/CodeX/gantor-openhands/config.qadr.example.toml)
- [`deploy/qadr-hands.caddyfile`](/C:/Users/never/Documents/CodeX/gantor-openhands/deploy/qadr-hands.caddyfile)
- [`deploy/qadr-agent-server.Dockerfile`](/C:/Users/never/Documents/CodeX/gantor-openhands/deploy/qadr-agent-server.Dockerfile)
- [`scripts/build-qadr-agent-server.sh`](/C:/Users/never/Documents/CodeX/gantor-openhands/scripts/build-qadr-agent-server.sh)
- [`scripts/deploy-qadr-openhands.sh`](/C:/Users/never/Documents/CodeX/gantor-openhands/scripts/deploy-qadr-openhands.sh)
- [`scripts/verify-qadr-openhands.sh`](/C:/Users/never/Documents/CodeX/gantor-openhands/scripts/verify-qadr-openhands.sh)
- [`scripts/publish-to-qadr.ps1`](/C:/Users/never/Documents/CodeX/gantor-openhands/scripts/publish-to-qadr.ps1)

## Recommended host paths
- state: `/srv/data/openhands-state`
- workspace: `/srv/data/openhands-workspace`

## Minimal rollout on QADR
1. Create the host directories.
2. Copy `.env.qadr.example` to `.env.qadr` and adjust values if needed.
3. Create `config.toml` inside the state directory from `config.qadr.example.toml`.
4. Generate a strong value for `FREEGPT_OPENHANDS_SESSION_SECRET`.
5. Leave the default `config.toml` on the direct local `Ollama` route unless you explicitly want to move the app back to the shared LiteLLM gateway.
6. Start the stack:

```bash
docker compose --env-file .env.qadr -f compose.qadr.yaml up -d --build
```

## One-command rollout helpers
From the QADR server workspace:

```bash
bash scripts/deploy-qadr-openhands.sh
```

From the Windows operator workstation:

```powershell
$env:QADR_SSH_PASSWORD = 'REPLACE_WITH_PASSWORD'
& .\scripts\publish-to-qadr.ps1
```

## Reverse proxy
The source-of-truth ingress block is maintained in the QADR `freegpt` repository:
- [`Caddyfile`](/C:/Users/never/Documents/CodeX/freegpt/stacks/ingress-core/Caddyfile)

Expected site:
- `hands.gantor.ir -> qadr-openhands:3000`
- `/runtime/{port}/* -> host.docker.internal:{port}`

## DNS
Add:

```dns
hands    IN A    5.235.208.128
```

to the authoritative `gantor.ir` zone used by QADR.

## Notes
- The container needs `/var/run/docker.sock` because OpenHands local GUI launches sandbox/runtime containers.
- The QADR compose file mounts `config.toml` into `/app/config.toml` so the runtime can deterministically load the live service configuration.
- Use `SANDBOX_CONTAINER_URL_PATTERN` for the browser-facing runtime URL and `SANDBOX_INTERNAL_CONTAINER_URL_PATTERN` for internal container-to-container health checks.
- Set `SANDBOX_STARTUP_GRACE_SECONDS=90` on QADR so Playwright/browser-use preload does not mark fresh sandboxes as failed before Chromium and VS Code finish booting.
- Set `SANDBOX_DOCKER_NETWORK=fgpt_ai` so runtime containers can reach `qadr-openhands` over the same Docker network as the ingress and AI stack.
- Set `SANDBOX_INTERNAL_CONTAINER_URL_PATTERN=http://{sandbox_id}:8000` so `qadr-openhands` talks to each runtime directly by container name instead of bouncing through random host ports.
- Set `SANDBOX_WEBHOOK_BASE_URL=http://qadr-openhands:3000/api/v1/webhooks` so runtime event delivery does not depend on host loopback publishing.
- Set `OH_INTERNAL_MCP_URL=http://qadr-openhands:3000` and trust that host for `/mcp` requests so the sandbox can list tools without being bounced to the public FreeGPT login screen.
- Internal webhook callbacks are allowed from trusted Docker-network CIDRs defined in `FREEGPT_OPENHANDS_INTERNAL_WEBHOOK_CIDRS`, so sandbox event delivery does not bounce off the FreeGPT login wall.
- The recommended QADR profile uses the direct local `Ollama` endpoint on `http://qadr-local-llm-ollama:11434` for `ollama/qwen2.5:3b`, because the OpenHands SDK resolves `ollama/*` models against the native Ollama API rather than an OpenAI-compatible `/v1` gateway.
- The dedicated QADR agent-server image extends the upstream `ghcr.io/openhands/agent-server` image and installs `playwright`, `browser-use`, and Chromium inside the sandbox runtime.
- `FREEGPT_OPENHANDS_SESSION_SECRET` is mandatory when login is enabled; without it, the login page can render but successful session issuance will fail.
- Settings, provider secrets, and conversation metadata are stored under `/.openhands/users/<user-id>/...`.
- The deploy helper normalizes both `settings.json` and `config.toml` to the effective runtime profile so newly authenticated users inherit the operator-managed model/base URL instead of a stale per-user config.
- This fork keeps upstream OpenHands functionality intact and adds Persian UI support, FreeGPT-backed auth, and QADR-specific deployment packaging.

## Recommended operational tuning
The QADR runtime is optimized for local-model browsing and tool use, not for very large prompt contexts.

Keep these defaults unless you are intentionally debugging the prompting stack:

```env
FREEGPT_OPENHANDS_LOAD_PUBLIC_SKILLS=false
FREEGPT_OPENHANDS_LOAD_USER_SKILLS=false
FREEGPT_OPENHANDS_LOAD_PROJECT_SKILLS=true
FREEGPT_OPENHANDS_LOAD_ORG_SKILLS=false
QADR_OPENHANDS_LLM_TIMEOUT=360
QADR_OPENHANDS_LLM_MAX_MESSAGE_CHARS=12000
QADR_OPENHANDS_LLM_MAX_OUTPUT_TOKENS=1200
QADR_OPENHANDS_LLM_NUM_RETRIES=2
QADR_OPENHANDS_LLM_RETRY_MIN_WAIT=2
QADR_OPENHANDS_LLM_RETRY_MAX_WAIT=8
QADR_OPENHANDS_LLM_RETRY_MULTIPLIER=2
QADR_OPENHANDS_LLM_CACHING_PROMPT=false
QADR_OPENHANDS_LLM_REASONING_EFFORT=none
QADR_OPENHANDS_LLM_ENABLE_ENCRYPTED_REASONING=false
QADR_OPENHANDS_LLM_EXTENDED_THINKING_BUDGET=0
```

Why this profile is preferred on QADR:
- it prevents the agent from loading the full public skill catalogue into every operational task
- it keeps `ollama/qwen2.5:7b` inside a prompt size that can complete reliably on the local Ollama service
- it avoids expensive reasoning defaults that are useful for frontier hosted models but unnecessary for the local browsing/runtime path
- it reduces the chance that a browser task stalls for five minutes and then fails inside Ollama

## Recommended runtime profile
Use this profile inside `/srv/data/openhands-state/config.toml` on QADR:

```toml
[llm]
model = "ollama/qwen2.5:3b"
base_url = "http://qadr-local-llm-ollama:11434"
ollama_base_url = "http://qadr-local-llm-ollama:11434"
api_key = "ollama-local-placeholder"
temperature = 0.0
max_budget_per_task = 0.0
```

Why this is the preferred path on QADR:
- it keeps Playwright/browser agents on a local model by default, so browsing/dev tasks do not depend on external provider quota or WAN latency
- it matches the native provider behavior expected by `ollama/*` inside the OpenHands SDK
- it can still be swapped to the shared LiteLLM gateway later without changing the deployment shape
- `ollama/qwen2.5:3b` is the recommended operational default for QADR because it reaches usable browser-agent latency much more reliably than `7b` on this host.
- If you need a slower but potentially stronger local reasoning profile, you can still override the model back to `ollama/qwen2.5:7b`.

## Authentication
- Login is validated against the internal Open WebUI service by default on QADR: `http://qadr-openwebui-app:8080/api/v1/auths/signin`.
- If you intentionally need the public route instead, override `FREEGPT_AUTH_BASE_URL`.
- After successful login, OpenHands issues its own signed cookie for `hands.gantor.ir`.
- If you need to disable auth temporarily for maintenance, set `FREEGPT_OPENHANDS_REQUIRE_LOGIN=false`.

## Ingress Checklist
1. Route normal traffic for `hands.gantor.ir` to `qadr-openhands:3000`.
2. Add a runtime path matcher for `/runtime/{port}/*`.
3. Strip `/runtime/{port}` from the request URI before proxying to `host.docker.internal:{port}`.
4. Reload Caddy and confirm a conversation websocket no longer attempts direct access to `:49xxx` on the public host.
5. If the ingress Caddy container does not already resolve `host.docker.internal`, add `extra_hosts: ["host.docker.internal:host-gateway"]` to that service.
