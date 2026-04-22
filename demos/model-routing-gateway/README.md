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

Praxis handles path normalization, provider credential
injection, upstream TLS, and Host header rewriting — all
inline without ext-proc.

## What is replaced

| Current Component | Praxis Replacement |
|---|---|
| ext_proc gRPC sidecar | eliminated |
| EnvoyFilter for ext_proc | eliminated |
| Envoy upstream routing | Praxis `router` + `load_balancer` |
| ExternalName Service | Praxis upstream TLS with DNS resolution |
| apikey-injection plugin | `request_set` filter (static config) |
| Host header rewrite | `request_set` filter |
| Path normalization | `path_rewrite` filter |

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
