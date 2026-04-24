# Praxis Demos

Praxis replaces the ext-proc/BBR/wasm-shim pipeline in
MaaS by doing body-aware routing inline. These demos
prove the replacement end-to-end on a live MaaS cluster.

## Current Status

| Demo | What it proves | Result |
|------|---------------|--------|
| [bbr-replacement](bbr-replacement/) | Body-based model routing with body forwarding to backends | **6/6 passing** |
| [model-routing-gateway](model-routing-gateway/) | Real OpenAI completions through Praxis via upstream TLS | **2/2 passing** |
| MaaS gpt-4o (existing stack) | Auth/subscription flow still works alongside Praxis | **4/5 passing** (404 expected — ext-proc not deployed) |

Full validation: `scripts/validate-all.sh` — **12 passed, 1 expected failure**.

## Request Flow — What Praxis Replaces

### Before (current MaaS stack)

```
1. Client sends POST /llm/gpt-4o/v1/chat/completions
   Body: {"model":"gpt-4o","messages":[...]}
   Header: Authorization: Bearer <maas-api-key>

2. DNS → AWS ELB → Envoy gateway pod (Istio)

3. Envoy runs Kuadrant Wasm plugin
   → Authorino ext-auth gRPC call
   → validates MaaS API key
   → checks subscription + rate limits via Limitador

4. Envoy runs ext_proc filter (gRPC call to payload-processing pod)
   → body-field-to-header plugin reads body, extracts "model" → X-Gateway-Model-Name: gpt-4o
   → model-provider-resolver plugin resolves gpt-4o → api.openai.com
   → api-translation plugin normalizes request format
   → apikey-injection plugin injects provider API key from K8s Secret

5. Envoy routes by X-Gateway-Model-Name header
   → selects ExternalName Service → api.openai.com:443

6. Envoy connects upstream TLS, forwards request

7. OpenAI responds → Envoy forwards to client
```

**Components in the body path:** ext_proc gRPC sidecar,
payload-processing pod (4 plugins), EnvoyFilter CRD,
DestinationRule, ServiceAccount + RBAC.

### After (Praxis replaces steps 4-6)

#### Demo 1 — BBR Replacement (body routing to internal backends)

```
1. Client sends POST /praxis/v1/chat/completions/
   Body: {"model":"qwen","messages":[{"role":"user","content":"hello"}]}
   Header: Authorization: Bearer <k8s-token>

2. DNS → AWS ELB → Envoy gateway pod (Istio)

3. Envoy runs Kuadrant Wasm plugin
   → Authorino validates K8s token (audience: maas-default-gateway-sa)
   → TokenRateLimitPolicy allows 100 req/min

4. HTTPRoute matches PathPrefix /praxis → forwards to Praxis Service :8080

5. Praxis receives request on listener :8080
   Filter chain: observability → classify → route

6. observability chain:
   → request_id: generates X-Request-ID header
   → access_log: logs method, path, client IP, timing

7. classify chain:
   → model_to_header: activates StreamBuffer mode
     a. Reads request body from downstream (may be one or multiple chunks)
     b. Parses JSON, extracts top-level "model" field → "qwen"
     c. Promotes value to request header: X-AI-Model: qwen
     d. Returns Release — body is buffered for upstream replay
     e. All chunks (including post-Release) are stored in pre_read_body deque

8. route chain:
   → router: matches path_prefix "/praxis/v1/chat/completions/"
     + header x-ai-model: "qwen" → selects cluster "qwen"
   → load_balancer: selects endpoint 172.30.x.x:8080 from cluster "qwen"

9. Pingora connects to upstream (echo-qwen pod)
   → initial body send: request_body_filter is called
   → pre_read_body deque is popped → full original body sent to upstream
   → upstream receives: {"model":"qwen","messages":[{"role":"user","content":"hello"}]}

10. echo-qwen pod reads body, returns JSON with forwarded_model + forwarded_prompt
    → proves body arrived intact

11. Praxis forwards response to gateway → client receives:
    {"model":"qwen","forwarded_model":"qwen","forwarded_prompt":"hello",...}
```

**Components in the body path:** Praxis pod only. No
ext_proc, no gRPC sidecar, no Wasm, no separate plugins.

#### Demo 2 — Provider Gateway (external model via TLS)

```
1. Client sends POST /praxis-gw/v1/chat/completions
   Body: {"model":"gpt-4o","messages":[...],"max_tokens":5}
   Header: Authorization: Bearer <k8s-token>

2. DNS → ELB → Envoy → Authorino (same as Demo 1 steps 2-3)

3. HTTPRoute matches PathPrefix /praxis-gw → forwards to Praxis Service :8080

4. Praxis receives request on listener :8080
   Filter chain: observability → normalize → inject-credentials → route

5. observability chain:
   → request_id + access_log (same as Demo 1)

6. normalize chain:
   → path_rewrite: condition matches path_prefix "/praxis-gw/"
     strips prefix → path becomes /v1/chat/completions

7. inject-credentials chain:
   → headers filter with request_set:
     a. Overwrites Authorization header: Bearer <openai-api-key>
        (replaces the K8s token with the provider key)
     b. Overwrites Host header: api.openai.com
        (replaces the gateway hostname for Cloudflare routing)

8. route chain:
   → router: matches path_prefix "/" → selects cluster "openai"
   → load_balancer: resolves DNS api.openai.com → 172.66.x.x:443
     establishes upstream TLS with SNI: api.openai.com

9. Pingora sends request to api.openai.com over TLS
   Path: /v1/chat/completions (rewritten)
   Host: api.openai.com (overwritten)
   Authorization: Bearer sk-proj-... (overwritten)
   Body: original JSON forwarded intact

10. OpenAI processes request, returns completion

11. Praxis forwards response to gateway → client receives:
    {"model":"gpt-4o-2024-08-06","choices":[{"message":{"content":"Ok."}}],...}
```

**Components in the body path:** Praxis pod only. DNS
resolution, TLS, credential injection, and path rewriting
all happen inline in the proxy.

## What Praxis Replaces

| MaaS Component | What it does | Praxis replacement | Status |
|---|---|---|---|
| ext-proc gRPC sidecar | Separate process for body inspection | Eliminated — inline in Praxis | **Done** |
| EnvoyFilter for ext-proc | Wires ext-proc into Envoy | Eliminated — not needed | **Done** |
| body-field-to-header plugin | Extracts `model` from JSON body → header | `model_to_header` filter | **Done** (Demo 1) |
| model-provider-resolver plugin | Maps model name → provider endpoint | `router` filter (static config) | **Done** (Demo 2) |
| apikey-injection plugin | Injects provider API key | `request_set` filter | **Done** (Demo 2) |
| ExternalName Service | DNS-based routing to api.openai.com | Praxis upstream TLS with DNS resolution | **Done** (Demo 2) |
| Envoy upstream routing | Routes to backend by header | `router` + `load_balancer` | **Done** |

## What Still Needs Work

| Issue | Detail |
|---|---|
| api-translation plugin | Praxis can't translate between provider API schemas (e.g. OpenAI → Anthropic format) |
| Secret-backed credentials | API key is hardcoded in the ConfigMap; production needs K8s Secret mount + injection |
| Combined body-inspect + external TLS | Demo 1 does body inspection, Demo 2 does external TLS; combining in one hop is not yet validated |

## Praxis Features Used

These demos run on the [`feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers)
branch of `nerdalert/praxis`:

| Feature | What it does |
|---------|-------------|
| **DNS resolution** | Upstream endpoints accept hostnames (`api.openai.com:443`) instead of requiring IP:port |
| **`request_set` / `request_remove`** | Header filter overwrites or removes request headers before upstream |
| **StreamBuffer body forwarding** | All body chunks buffered for replay regardless of filter Release state |

Image: `ghcr.io/nerdalert/praxis:maas-dev` (public)

## Deployment

Each demo has its own `deploy.sh` and `validate.sh`:

```bash
./demos/bbr-replacement/deploy.sh
./demos/bbr-replacement/validate.sh

export OPENAI_API_KEY='sk-...'
./demos/model-routing-gateway/deploy.sh
./demos/model-routing-gateway/validate.sh
```

## Validation

### Demo 1: BBR Replacement — model-based routing

```bash
GW_HOST=$(oc -n openshift-ingress get gateway maas-default-gateway \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN=$(oc create token default -n llm --audience=maas-default-gateway-sa)
```

Route to qwen backend — body is forwarded and echoed:

```bash
$ curl -sk "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

{"id":"chatcmpl-demo","model":"qwen","forwarded_model":"qwen","forwarded_prompt":"hello",...}
```

Route to mistral backend:

```bash
$ curl -sk "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"mistral","messages":[{"role":"user","content":"hello"}]}'

{"id":"chatcmpl-demo","model":"mistral","forwarded_model":"mistral","forwarded_prompt":"hello",...}
```

Auth rejection:

```bash
$ curl -sk -w "HTTP %{http_code}" "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

HTTP 401
```

### Demo 2: Provider Gateway — real OpenAI

```bash
$ curl -sk "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}'

{"model":"gpt-4o-2024-08-06","choices":[{"message":{"content":"Ok."}}],"usage":{"total_tokens":13}}
```

### Full suite

```bash
./scripts/validate-all.sh
```

## Prerequisites

- MaaS deployed with `maas-default-gateway`
- `oc` authenticated as cluster admin
- `ghcr.io/nerdalert/praxis:maas-dev` image (public)
- OpenAI API key for Demo 2
