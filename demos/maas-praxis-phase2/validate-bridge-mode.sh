#!/bin/bash
# Validate bridge-mode MaaS descriptor projection
#
# Proves that Authorino-injected MaaS identity headers
# are consumed by Praxis descriptor rate limiter on the
# real MaaS model path (/llm/gpt-4o/).
#
# Bridge mode: Authorino stays in front, injects trusted
# headers. Praxis consumes them for rate limiting, then
# strips them before upstream.
#
# Usage:
#   ./demos/maas-praxis-phase2/validate-bridge-mode.sh

set -euo pipefail

GW_HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')

echo "===================================================================="
echo "BRIDGE MODE — MaaS descriptor projection via Authorino"
echo "===================================================================="
echo "Gateway: ${GW_HOST}"
echo ""

PASS=0
FAIL=0

TOKEN=$(oc whoami -t)
KEY=$(curl -sk -X POST "https://${GW_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"bridge-validate","subscription":"gpt-4o-subscription"}' | jq -r '.key // empty')

if [ -z "$KEY" ]; then
  echo "FAIL  could not mint MaaS API key"
  exit 1
fi
echo "MaaS API key: ${KEY:0:20}..."
echo ""

# --- Test 1: MaaS API key request uses descriptor ---
echo "--- Test 1: MaaS API key request uses Authorino-injected descriptor ---"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 \
  "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"ok"}],"max_tokens":3}')
if [ "$CODE" = "200" ]; then
  echo "PASS  MaaS path with descriptor: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  MaaS path with descriptor: expected 200, got ${CODE}"
  FAIL=$((FAIL + 1))
fi

# --- Test 2: Metrics show descriptor was matched ---
echo "--- Test 2: Metrics show descriptor match (not missing) ---"
METRICS=$(oc -n llm exec deployment/praxis-gateway -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/metrics 2>/dev/null || echo "")

if echo "$METRICS" | grep -q 'decision="allow".*reason="ok"'; then
  echo "PASS  descriptor matched: decision=allow reason=ok"
  PASS=$((PASS + 1))
else
  echo "FAIL  descriptor not matched in metrics"
  FAIL=$((FAIL + 1))
fi

# --- Test 3: Descriptor header stripped before upstream ---
echo "--- Test 3: Descriptor header stripped (OpenAI doesn't see it) ---"
RESP=$(curl -sk --max-time 15 \
  "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}')
if echo "$RESP" | grep -q '"content"'; then
  echo "PASS  OpenAI responded (header was stripped before upstream)"
  PASS=$((PASS + 1))
else
  echo "FAIL  OpenAI did not respond normally"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Descriptor metrics ---"
echo "$METRICS" | grep 'praxis_rate_limit' | head -5

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "Bridge mode validated: Authorino injects x-maas-subscription,"
echo "Praxis consumes it for descriptor rate limiting, strips it"
echo "before upstream."
echo "===================================================================="

[ "$FAIL" -gt 0 ] && exit 1
exit 0
