# MaaS + Praxis Integration

Praxis replaces the ext-proc/BBR/wasm-shim pipeline in
MaaS by doing body-aware routing, credential injection,
and provider egress inline — no gRPC sidecar, no Wasm,
no external processor.

## Current Status

| Test | Result |
|------|--------|
| Body-based model routing (mock backends) | **Passing** |
| Body forwarding verified (upstream echoes body) | **Passing** |
| External model via Praxis → OpenAI | **Passing** |
| MaaS API key auth → Praxis → OpenAI | **Passing** |
| In-cluster model (facebook/opt-125m simulator) | **Passing** |
| Auth rejection (bogus keys, no auth) | **Passing** |

## What Praxis Replaces

| MaaS Component | What it does | Praxis replacement | Status |
|---|---|---|---|
| ext-proc gRPC sidecar | Separate process for body inspection | Eliminated — inline in Praxis | **Done** |
| EnvoyFilter for ext-proc | Wires ext-proc into Envoy | Eliminated — not needed | **Done** |
| body-field-to-header plugin | Extracts `model` from JSON body → header | `model_to_header` filter | **Done** |
| model-provider-resolver plugin | Maps model name → provider endpoint | `router` filter (static config) | **Done** |
| apikey-injection plugin | Injects provider API key | `request_set` filter | **Done** |
| ExternalName Service | DNS-based routing to provider | Praxis upstream TLS with DNS resolution | **Done** |
| Envoy upstream routing | Routes to backend by header | `router` + `load_balancer` | **Done** |

## What Is NOT Replaced

| MaaS Component | What it does | Status |
|---|---|---|
| Authorino | API key validation, K8s token auth, OPA policies | **Unchanged** — runs before Praxis |
| Limitador | Token rate limiting per subscription | **Unchanged** — runs before Praxis |
| maas-api | API key minting, subscription management | **Unchanged** |
| MaaS controller | Reconciles ExternalModel/MaaSModelRef CRDs | **Unchanged** |
| MaaS CRDs | ExternalModel, MaaSModelRef, MaaSAuthPolicy, MaaSSubscription | **Unchanged** |
| KServe | LLMInferenceService lifecycle, HTTPRoute creation | **Unchanged** |
| api-translation plugin | Provider schema translation (OpenAI ↔ Anthropic) | **Not implemented** in Praxis |
| model-provider-resolver (dynamic) | Runtime CRD-driven model→endpoint resolution | **Static config** only — needs config adapter for dynamic |
| Secret-backed credentials | API key from K8s Secret at runtime | **Static config** — key injected at deploy time |

## Request Flow

### ExternalModel (gpt-4o → OpenAI via Praxis)

```
1. Client POST /llm/gpt-4o/v1/chat/completions
   Authorization: Bearer sk-oai-<maas-api-key>

2. Gateway → Authorino validates MaaS API key + subscription

3. HTTPRoute /llm/gpt-4o → backendRef praxis-gateway:8080
   (patched from ExternalName Service to Praxis)

4. Praxis path_rewrite: /llm/gpt-4o/v1/chat/completions → /v1/chat/completions

5. Praxis request_set: Authorization → Bearer sk-proj-<openai-key>
                        Host → api.openai.com

6. Praxis router → cluster "openai"
   load_balancer → DNS resolve api.openai.com → upstream TLS (SNI)

7. OpenAI responds → Praxis → Gateway → Client
```

### LLMInferenceService (facebook/opt-125m → in-cluster simulator)

```
1. Client POST /llm/facebook-opt-125m-cpu/v1/chat/completions
   Authorization: Bearer sk-oai-<maas-api-key>

2. Gateway → Authorino validates MaaS API key + subscription

3. KServe HTTPRoute /llm/facebook-opt-125m-cpu → workload Service :8000
   (no Praxis in this path — KServe routes directly)

4. Simulator responds → Gateway → Client
```

### BBR Replacement (body routing to mock backends)

```
1. Client POST /praxis/v1/chat/completions/
   Body: {"model":"qwen","messages":[...]}
   Authorization: Bearer <k8s-token>

2. Gateway → Authorino validates K8s token

3. HTTPRoute /praxis → praxis:8080

4. Praxis model_to_header: reads body via StreamBuffer,
   extracts "model" → X-AI-Model: qwen

5. Praxis router: matches header → cluster "qwen"
   load_balancer → echo-qwen pod

6. Body replayed to upstream via request_body_filter

7. Echo backend reads body, returns forwarded_model + forwarded_prompt
```

## Praxis Features Required

Branch: [`nerdalert/praxis` `feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers)

| Feature | What it does |
|---------|-------------|
| DNS resolution | Upstream endpoints accept hostnames |
| `request_set` / `request_remove` | Overwrite or remove request headers before upstream |
| StreamBuffer body forwarding | All body chunks buffered for replay after inspection |

Image: `ghcr.io/nerdalert/praxis:maas-dev` (public)

## Deploy

```bash
# Prerequisites: MaaS deployed, ExternalModel created (see docs/install.md)

OPENAI_API_KEY='sk-...' ./demos/maas-praxis/deploy.sh
```

## Validate

```bash
./demos/maas-praxis/validate.sh
```

### Expected output

```
BBR REPLACEMENT — body-based model routing
  PASS  model=qwen routes and forwards body: HTTP 200
  PASS  model=mistral routes and forwards body: HTTP 200
  PASS  no auth rejected: HTTP 401

PROVIDER GATEWAY — gpt-4o via Praxis → OpenAI
  PASS  chat completion via /praxis-gw/: HTTP 200
  PASS  provider route no auth rejected: HTTP 401

MAAS MODEL PATH — gpt-4o with MaaS API key through Praxis
  PASS  gpt-4o via MaaS API key: HTTP 200
  PASS  bogus key rejected: HTTP 403
  PASS  no auth rejected: HTTP 401

Results: 8 passed, 0 failed, 0 skipped
```

## Additional validation scripts

| Script | What it tests |
|--------|--------------|
| `scripts/validate-all.sh` | Full suite including all demos + MaaS auth flow |
| `scripts/validate-maas-path-gpt.sh` | gpt-4o MaaS path in detail (8 tests) |
| `scripts/validate-maas-all-models.sh` | All models: gpt-4o + facebook/opt-125m simulator |
