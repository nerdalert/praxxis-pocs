# Demo: Model Routing Gateway

## What this proves

Praxis replaces Envoy as the model-routing proxy for
external provider traffic. Instead of:

```
Client → Envoy → ext_proc/BBR → Envoy routes
→ ExternalName Service → api.openai.com
```

Praxis is the routing proxy:

```
Client → Gateway → Praxis
  → model_to_header (body extraction)
  → router (model → provider cluster)
  → upstream TLS to api.openai.com
→ OpenAI response
```

Praxis handles body-based model extraction, provider
routing, upstream TLS, and API key injection — all
inline without ext-proc.

## What is replaced

| Current Component | Praxis Replacement |
|---|---|
| BBR body-field-to-header | `model_to_header` filter |
| ext_proc gRPC sidecar | eliminated |
| EnvoyFilter for ext_proc | eliminated |
| Envoy upstream routing | Praxis `router` + `load_balancer` |
| ExternalName Service | Praxis upstream TLS cluster |

## Current status

**Blocked on `request_set`/`request_remove`.** Praxis can
only ADD request headers, not replace them. When proxying
to an external provider:

- The client's `Host` header (from the gateway) is
  forwarded alongside the added `Host: api.openai.com`,
  creating a duplicate that the provider rejects
- The client's `Authorization` header needs to be REPLACED
  with the provider key, not appended to

This demo deploys and connects (DNS resolution, TLS
handshake, and SNI all work), but the request fails at
the provider because of the duplicate Host header.

**Unblocked once Praxis adds:**
- `request_set` — overwrite an existing request header
- `request_remove` — strip a request header before upstream

## What is NOT replaced yet

| Component | Why |
|---|---|
| Host header rewrite | Needs `request_set` (only `request_add` exists) |
| api-translation | Provider schema translation not implemented |
| apikey-injection (from Secret) | Uses static `request_add`; needs `request_set` for production |

## Prerequisites

- MaaS deployed with `maas-default-gateway`
- OpenAI API key (set `OPENAI_API_KEY` env var)
- DNS resolution patch on Praxis fork (`nerdalert/praxis`)

## Deploy

```bash
export OPENAI_API_KEY='sk-...'
./demos/model-routing-gateway/deploy.sh
```

## Validate

```bash
./demos/model-routing-gateway/validate.sh
```
