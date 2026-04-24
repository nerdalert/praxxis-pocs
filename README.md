# Praxis POCs

Proof-of-concept demos for [Praxis](https://github.com/praxis-proxy/praxis), an AI-native proxy built on Pingora.

These demos show Praxis replacing components in a MaaS (Models-as-a-Service) gateway stack — body-aware model routing, provider egress, and request classification without ext-proc or Wasm sidecars.

## Praxis Changes

These demos require features on two branches:

**[`nerdalert/praxis` `feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers)**

| Feature | What it does |
|---------|-------------|
| **DNS resolution** | Upstream endpoints accept DNS hostnames (e.g. `api.openai.com:443`) instead of requiring IP:port |
| **`request_set` / `request_remove`** | Header filter can overwrite or remove request headers before upstream — needed for Host rewrite and provider credential injection |
| **StreamBuffer body forwarding** | All body chunks are buffered for replay regardless of filter Release state |

**[`nerdalert/pingora` `feat/streambuffer-initial-send`](https://github.com/nerdalert/pingora/tree/feat/streambuffer-initial-send)**

| Feature | What it does |
|---------|-------------|
| **Initial body send for pre-read bodies** | Ensures `request_body_filter` is called when downstream body was consumed during pre-read, enabling body replay to upstream |

Image: `ghcr.io/nerdalert/praxis:maas-dev` (public, includes all features)

## Demo

See [demos/maas-praxis/](demos/maas-praxis/) for the consolidated MaaS + Praxis integration demo.

## Docs

- [docs/install.md](docs/install.md) — MaaS + Praxis install runbook
- [docs/streambuffer.md](docs/streambuffer.md) — StreamBuffer body forwarding technical detail

## Scripts

- [`scripts/validate-all.sh`](scripts/validate-all.sh) — full integration test suite
- [`scripts/validate-maas-path-gpt.sh`](scripts/validate-maas-path-gpt.sh) — gpt-4o MaaS path validation
- [`scripts/validate-maas-all-models.sh`](scripts/validate-maas-all-models.sh) — all models (gpt-4o + facebook/opt-125m)

## Quick Start

```bash
# Prerequisites: MaaS deployed (see docs/install.md)

OPENAI_API_KEY='sk-...' ./demos/maas-praxis/deploy.sh
./demos/maas-praxis/validate.sh
```

## License

MIT
