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

## Features used

This demo uses two features added on the `nerdalert/praxis`
fork ([`feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers)):

- **DNS resolution** — upstream endpoints accept hostnames
  (e.g. `api.openai.com:443`)
- **`request_set`** — overwrites Host and Authorization
  headers for provider egress

## What is NOT replaced yet

| Component | Why |
|---|---|
| api-translation | Provider schema translation not implemented |
| apikey-injection (from Secret) | Uses static config; production needs Secret-backed injection |

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
