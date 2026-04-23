# Praxis POCs

Proof-of-concept demos for [Praxis](https://github.com/praxis-proxy/praxis), an AI-native proxy built on Pingora.

These demos show Praxis replacing components in a MaaS (Models-as-a-Service) gateway stack — body-aware model routing, provider egress, and request classification without ext-proc or Wasm sidecars.

## Praxis Changes

These demos require features on the [`feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers) branch of `nerdalert/praxis`:

| Feature | What it does |
|---------|-------------|
| **DNS resolution** | Upstream endpoints accept DNS hostnames (e.g. `api.openai.com:443`) instead of requiring IP:port |
| **`request_set` / `request_remove`** | Header filter can overwrite or remove request headers before upstream — needed for Host rewrite and provider credential injection |
| **StreamBuffer body forwarding fix** | All body chunks are buffered for replay regardless of filter Release state — fixes body forwarding to upstream backends after body inspection |

Image: `ghcr.io/nerdalert/praxis:maas-dev` (public, includes all three features)

## Demos

See [demos/](demos/) for deployment instructions, architecture diagrams, and curl examples.

## Scripts

- [`scripts/validate-all.sh`](scripts/validate-all.sh) — full integration test suite covering Praxis BBR replacement, Praxis provider gateway, and existing MaaS gpt-4o routes

## Validation

```bash
# Deploy demos (see maas-paxxis-install.md for full runbook)
./demos/bbr-replacement/deploy.sh
OPENAI_API_KEY='sk-...' ./demos/model-routing-gateway/deploy.sh

# Validate everything
./scripts/validate-all.sh
```

Expected: 12+ passed, 1 failed (MaaS gpt-4o 404 — ext-proc not deployed because Praxis replaces it).

## License

MIT
