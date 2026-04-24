# MaaS + Praxis Install (Working Runbook)

Last verified: 2026-04-23 on `ci-ln-6vknt7b-76ef8.aws-4.ci.openshift.org`

This runbook reproduces the full working POC on a fresh cluster:

- MaaS deployed with ODH operator
- ExternalModel (`gpt-4o`) configured
- Praxis BBR replacement route (`/praxis/*`) — body-based
  model routing to mock backends with the Praxis-side
  StreamBuffer replay fix
- Praxis provider gateway route (`/praxis-gw/*`) — real
  OpenAI completions through Praxis
- `scripts/validate-all.sh` passing (`12 passed, 1 failed`,
  where the `404` is the expected MaaS/ext-proc gap)

## Prerequisites

- Fresh OpenShift cluster with `oc` access as `kube:admin`
- `~/praxxis/models-as-a-service` cloned
- `~/praxxis/praxxis-pocs` cloned
  ([github.com/nerdalert/praxis-pocs](https://github.com/nerdalert/praxis-pocs))
- `OPENAI_API_KEY` for the provider gateway demo
- Image `ghcr.io/nerdalert/praxis:maas-dev` is public on GHCR
  and currently validated at
  `ghcr.io/nerdalert/praxis@sha256:51c89d6f9debdb4b25967518b64df7b922ebd4d2493b30d336b4cdf4ed2e315a`

## Timing

| Step | Wall time |
|------|-----------|
| `deploy.sh` | ~5 min (no output until done) |
| Gateway programmed | ~1-2 min after deploy |
| ODH operator ready | ~2 min after gateway |
| maas-api + controller ready | ~2 min after ODH operator |
| Praxis demos deployed | ~2 min each |
| Total | ~12-15 min |

## 1. Deploy MaaS (ODH)

```bash
cd ~/praxxis/models-as-a-service
./scripts/deploy.sh --operator-type odh
```

The script produces no output until it finishes. Check
progress with:

```bash
oc get pods -A | grep -c Running
```

## 2. Wait for gateway

```bash
oc -n openshift-ingress get gateway maas-default-gateway
```

Wait until `PROGRAMMED` shows `True`.

## 3. Apply Authorino runtime workaround

Required on every fresh cluster. Without this, the
gateway returns `500` and logs show
`wasm log ... gRPC status code is not OK`.

```bash
oc -n kuadrant-system patch authorino authorino --type=merge \
  -p '{"spec":{"listener":{"tls":{"enabled":false}}}}'

oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

oc -n kuadrant-system scale deployment/authorino-operator --replicas=0

# Serve gRPC with the OpenShift service serving cert.
# The wasm plugin connects over TLS to port 50051 — Authorino
# must serve TLS there using the auto-generated cert from the
# authorino-server-cert secret.
oc -n kuadrant-system patch deployment authorino --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":[
    "--allow-superseding-host-subsets",
    "--tls-cert=/etc/ssl/certs/authorino-server/tls.crt",
    "--tls-cert-key=/etc/ssl/certs/authorino-server/tls.key"
  ]}]'

oc -n kuadrant-system patch deployment authorino --type='strategic' -p '{
  "spec":{"template":{"spec":{
    "volumes":[
      {"name":"openshift-service-ca","configMap":{"name":"openshift-service-ca.crt","items":[{"key":"service-ca.crt","path":"service-ca-bundle.crt"}]}},
      {"name":"authorino-server-cert","secret":{"secretName":"authorino-server-cert"}}
    ],
    "containers":[{"name":"authorino","volumeMounts":[
      {"name":"openshift-service-ca","mountPath":"/etc/ssl/certs/openshift-service-ca","readOnly":true},
      {"name":"authorino-server-cert","mountPath":"/etc/ssl/certs/authorino-server","readOnly":true}
    ]}]
  }}}}'

oc -n kuadrant-system rollout restart deployment/authorino
oc -n kuadrant-system rollout status deployment/authorino --timeout=240s
```

**Note:** `authorino-operator` is scaled to `0` so it does
not reconcile away the manual patches. However, the Kuadrant
policy controller requires the Authorino CR status to show
`Ready: True` to enforce AuthPolicies. After applying the
patches, briefly scale the operator back up to reconcile
the status, then scale it back down:

```bash
oc -n kuadrant-system scale deployment/authorino-operator --replicas=1
sleep 30
oc -n kuadrant-system scale deployment/authorino-operator --replicas=0
```

Verify AuthPolicies are enforced:

```bash
oc -n llm get authpolicy -o custom-columns='NAME:.metadata.name,ENFORCED:.status.conditions[?(@.type=="Enforced")].status'
```

All should show `True`. If any show `False`, the operator
did not run long enough — repeat the scale up/down cycle.

## 4. Wait for maas-api and controller

```bash
oc get pods -A --no-headers | grep -E 'maas-api|maas-controller'
```

Wait until both show `Running`. maas-api may
CrashLoopBackOff initially if it starts before the
controller creates the DB secret — it self-heals within
1-2 restart cycles.

## 5. Create ExternalModel + MaaS resources

```bash
oc create namespace llm 2>/dev/null || true
# NOTE: do NOT label with istio-injection=enabled.
# Istio sidecar injection causes init container hangs for
# the Python echo backends and Praxis pods. Praxis handles
# its own upstream TLS — no mesh sidecar needed.

export OPENAI_API_KEY='<replace-me>'

oc -n llm create secret generic openai-api-key \
  --from-literal=api-key="$OPENAI_API_KEY"
oc -n llm label secret openai-api-key \
  inference.networking.k8s.io/bbr-managed=true --overwrite

oc apply -f - <<'YAML'
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: gpt-4o
  namespace: llm
spec:
  provider: openai
  endpoint: api.openai.com
  targetModel: gpt-4o
  credentialRef:
    name: openai-api-key
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: gpt-4o
  namespace: llm
spec:
  modelRef:
    kind: ExternalModel
    name: gpt-4o
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: gpt-4o-access
  namespace: models-as-a-service
spec:
  modelRefs:
  - name: gpt-4o
    namespace: llm
  subjects:
    groups:
    - name: "system:authenticated"
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: gpt-4o-subscription
  namespace: models-as-a-service
spec:
  owner:
    groups:
    - name: "system:authenticated"
  modelRefs:
  - name: gpt-4o
    namespace: llm
    tokenRateLimits:
    - limit: 100000
      window: "1h"
YAML
```

## 6. Deploy Praxis demos

**Note:** ext-proc/BBR is NOT deployed. Praxis replaces it,
including the body replay behavior needed for StreamBuffer
inspection.

### Demo 1: BBR replacement (body-based model routing)

```bash
~/praxxis/praxxis-pocs/demos/bbr-replacement/deploy.sh
```

### Demo 2: Provider gateway (real OpenAI)

```bash
export OPENAI_API_KEY='<replace-me>'
~/praxxis/praxxis-pocs/demos/model-routing-gateway/deploy.sh
```

## 7. Validate

Wait ~15 seconds for AuthPolicy enforcement, then:

```bash
~/praxxis/praxxis-pocs/scripts/validate-all.sh
```

### Expected results

```
DEMO 1: BBR REPLACEMENT
  PASS  model=qwen routes to qwen backend: HTTP 200
  PASS  model=mistral routes to mistral backend: HTTP 200
  PASS  no auth returns 401: HTTP 401
  PASS  bogus token returns 401: HTTP 401
  PASS  admin /ready returns ok

DEMO 2: MODEL ROUTING GATEWAY
  PASS  chat completion via Praxis → OpenAI: HTTP 200
  PASS  provider route no auth returns 401: HTTP 401

MAAS GPT-4O ROUTE
  FAIL  valid key, correct path: expected 200, got 404  ← expected
  PASS  bogus sk-oai- key: HTTP 403
  PASS  random token: HTTP 401
  PASS  no auth: HTTP 401
  PASS  header injection attempt: HTTP 401

Results: 11 passed, 1 failed, 0 skipped
```

The MaaS gpt-4o 404 is expected — ext-proc is not
deployed because Praxis replaces it.

## 8. Quick manual validation

```bash
GW_HOST=$(oc -n openshift-ingress get gateway maas-default-gateway \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN=$(oc create token default -n llm --audience=maas-default-gateway-sa)

# Demo 1: body-based model routing
curl -sk "https://${GW_HOST}/praxis/v1/chat/completions/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

curl -sk "https://${GW_HOST}/praxis/v1/chat/completions/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral","messages":[{"role":"user","content":"hello"}]}'

# Demo 2: real OpenAI through Praxis
curl -sk "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}'
```

## Known issues

| Issue | Detail | Workaround |
|-------|--------|------------|
| Istio sidecar injection | If `llm` namespace has `istio-injection=enabled`, echo backends and Praxis pods hang in `Init:1/2` | Do NOT label `llm` with `istio-injection=enabled`. Deploy scripts now remove the label automatically. |
| Authorino TLS | Gateway returns 500 without the workaround in step 3 | Apply step 3 on every fresh cluster |
| maas-api CrashLoop | Starts before DB secret exists | Self-heals in 1-2 restart cycles |
| AuthPolicy sync delay | Policies take 10-30s to enforce after creation | Wait before validating |
| Transient 404 after Authorino restart | Gateway wasm plugin has stale gRPC connection to Authorino after restart, causing intermittent 500/404 | Requests self-heal within 30-60s as connection pool recycles; or restart gateway pod |
| Streaming usage accounting | `/praxis-gw` SSE passthrough works, but the gateway wasm layer logs `Missing json property: /usage/total_tokens` on streamed chunks; even with `stream_options.include_usage=true`, usage only appears on the final chunk | Treat streaming transport as working; treat token accounting/showback for streams as not yet production-ready |
| Provider gateway 401 | OpenAI rejects the supplied API key upstream | Use a valid `OPENAI_API_KEY` before validating Demo 2 |
| MaaS gpt-4o 404 | ext-proc not deployed | Expected — Praxis replaces it |
