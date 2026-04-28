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
- Internal sandbox health checks through `host.docker.internal:{port}`

## Files
- [`compose.qadr.yaml`](/C:/Users/never/Documents/CodeX/gantor-openhands/compose.qadr.yaml)
- [`.env.qadr.example`](/C:/Users/never/Documents/CodeX/gantor-openhands/.env.qadr.example)
- [`config.template.toml`](/C:/Users/never/Documents/CodeX/gantor-openhands/config.template.toml)
- [`config.qadr.example.toml`](/C:/Users/never/Documents/CodeX/gantor-openhands/config.qadr.example.toml)
- [`deploy/qadr-hands.caddyfile`](/C:/Users/never/Documents/CodeX/gantor-openhands/deploy/qadr-hands.caddyfile)
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
5. Replace the default model/API settings in `config.toml` only if you want to use the managed LiteLLM gateway instead of local Ollama.
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
- The default QADR profile uses local Ollama on `http://qadr-local-llm-ollama:11434` with `ollama/qwen2.5:14b`, and keeps a commented LiteLLM profile ready for managed external routing.
- `FREEGPT_OPENHANDS_SESSION_SECRET` is mandatory when login is enabled; without it, the login page can render but successful session issuance will fail.
- Settings, provider secrets, and conversation metadata are stored under `/.openhands/users/<user-id>/...`.
- This fork keeps upstream OpenHands functionality intact and adds Persian UI support, FreeGPT-backed auth, and QADR-specific deployment packaging.

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
