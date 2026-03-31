# QADR Deployment

This fork is prepared for a Persian-first deployment on `hands.gantor.ir`.

## Scope
- Private, authenticated deployment of OpenHands on QADR (access restricted via Caddy `basic_auth`)
- Persian available in the UI language selector
- RTL-aware document language handling for Persian and Arabic
- Reverse proxy through the shared QADR Caddy ingress

## Files
- [`compose.qadr.yaml`](/C:/Users/never/Documents/CodeX/gantor-openhands/compose.qadr.yaml)
- [`.env.qadr.example`](/C:/Users/never/Documents/CodeX/gantor-openhands/.env.qadr.example)
- [`config.template.toml`](/C:/Users/never/Documents/CodeX/gantor-openhands/config.template.toml)
- [`config.qadr.example.toml`](/C:/Users/never/Documents/CodeX/gantor-openhands/config.qadr.example.toml)

## Recommended host paths
- state: `/srv/data/openhands-state`
- workspace: `/srv/data/openhands-workspace`

## Minimal rollout on QADR
1. Create the host directories.
2. Copy `.env.qadr.example` to `.env.qadr`. Set `JWT_SECRET` to a strong random value (used as the app-server encryption key).
3. Create `config.toml` inside the state directory from `config.qadr.example.toml`.
4. In `config.toml`, replace `REPLACE_WITH_LITELLM_MASTER_KEY` with a dedicated service key, and replace `REPLACE_WITH_STRONG_JWT_SECRET` with a separate strong random value (used for OpenHands session tokens).
5. Configure Caddy `basic_auth` for `hands.gantor.ir` (see [Restricting Access](#restricting-access)).
6. Start the stack:

```bash
docker compose --env-file .env.qadr -f compose.qadr.yaml up -d --build
```

## Reverse proxy
The source-of-truth ingress block is maintained in the QADR `freegpt` repository:
- [`Caddyfile`](/C:/Users/never/Documents/CodeX/freegpt/stacks/ingress-core/Caddyfile)

Expected site:
- `hands.gantor.ir -> qadr-openhands:3000`

## Restricting Access

The deployment is made private by adding Caddy [`basic_auth`](https://caddyserver.com/docs/caddyfile/directives/basic_auth)
in front of the reverse-proxy site block.  Add the following inside the `hands.gantor.ir` site block in the Caddyfile:

```caddyfile
hands.gantor.ir {
    basic_auth {
        # Generate hash with: caddy hash-password --plaintext YOUR_PASSWORD
        YOUR_USERNAME BCRYPT_HASH_OF_PASSWORD
    }
    reverse_proxy qadr-openhands:3000
}
```

Regenerate the hash any time the password changes:

```bash
docker run --rm caddy:2 caddy hash-password --plaintext 'YOUR_PASSWORD'
```

## DNS
Add:

```dns
hands    IN A    5.235.208.128
```

to the authoritative `gantor.ir` zone used by QADR.

## Notes
- The container needs `/var/run/docker.sock` because OpenHands local GUI launches sandbox/runtime containers.
- The QADR compose file mounts `config.toml` into `/app/config.toml` so the runtime can deterministically load the live service configuration.
- The recommended LLM path is the internal FreeGPT/LiteLLM API on `http://qadr-ai-gateway-litellm:4000/v1`, backed by a dedicated OpenHands service key rather than the LiteLLM master key.
- This fork keeps upstream OpenHands functionality intact and adds Persian UI support plus QADR-specific deployment packaging.
