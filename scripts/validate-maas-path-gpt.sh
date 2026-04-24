#!/bin/bash
# Validate the MaaS model path (/llm/gpt-4o/) routed through Praxis
#
# This tests the full MaaS auth + subscription flow with Praxis
# as the backend instead of ext-proc/BBR.
#
# Usage:
#   ./scripts/validate-maas-path.sh

set -euo pipefail

GW_HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
echo "Gateway: $GW_HOST"
echo ""

PASS=0
FAIL=0

check() {
  local name="$1" expect_code="$2" expect_body="${3:-}"
  shift 3
  local response code body
  response=$(curl -sk -w "\n%{http_code}" --max-time 15 "$@" 2>&1)
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [ "$code" = "$expect_code" ]; then
    if [ -n "$expect_body" ] && ! echo "$body" | grep -q "$expect_body"; then
      echo "FAIL  ${name}: HTTP ${code} but body missing '${expect_body}'"
      FAIL=$((FAIL + 1))
      return
    fi
    echo "PASS  ${name}: HTTP ${code}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  ${name}: expected ${expect_code}, got ${code}"
    echo "      body: ${body:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

echo "===================================================================="
echo "MAAS MODEL PATH — /llm/gpt-4o/ via Praxis"
echo "===================================================================="
echo ""

# --- Mint a MaaS API key via subscription ---

TOKEN=$(oc whoami -t)
KEY=$(curl -sk -X POST "https://${GW_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"validate-maas-path","subscription":"gpt-4o-subscription"}' \
  | jq -r '.key // empty')

if [ -z "$KEY" ]; then
  echo "FAIL  could not mint MaaS API key (maas-api may not be running)"
  exit 1
fi
echo "MaaS API key: ${KEY:0:20}..."
echo ""

# --- Chat completion with MaaS API key ---

echo "Model: gpt-4o (ExternalModel → api.openai.com via Praxis)"
echo "Path:  /llm/gpt-4o/v1/chat/completions"
echo ""

RAW=$(curl -sk -w "\n%{http_code}" --max-time 15 \
  "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}' 2>&1)
CODE=$(echo "$RAW" | tail -1)
BODY=$(echo "$RAW" | head -n -1)

if [ "$CODE" = "200" ]; then
  echo "$BODY" | jq .
  echo ""
  echo "PASS  chat completion with MaaS API key: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  chat completion with MaaS API key: expected 200, got ${CODE}"
  echo "      body: ${BODY:0:200}"
  FAIL=$((FAIL + 1))
fi

# --- K8s token on chat completions should be rejected ---
# MaaS AuthPolicy only accepts K8s tokens for /v1/models,
# not chat completions. Completions require sk-oai-* keys.

K8S_TOKEN=$(oc create token default -n llm --audience=https://kubernetes.default.svc 2>/dev/null || true)
if [ -n "$K8S_TOKEN" ]; then
  check "K8s token rejected for chat completions" 401 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $K8S_TOKEN" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'
fi

# --- Model listing ---

check "model listing" 200 "gpt-4o" \
  "https://${GW_HOST}/v1/models" \
  -H "Authorization: Bearer $KEY"

# --- Auth rejection ---

check "bogus sk-oai- key rejected" 403 "" \
  "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-oai-FAKE-KEY-12345" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

check "random token rejected" 401 "" \
  "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer randomgarbage" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

check "no auth rejected" 401 "" \
  "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

check "header injection rejected" 401 "" \
  "https://${GW_HOST}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer FAKE" \
  -H "X-Gateway-Model-Name: gpt-4o" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

# --- Praxis gateway health ---

HEALTH=$(oc -n llm exec deployment/praxis-gateway -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/ready 2>/dev/null || echo "UNREACHABLE")
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  echo "PASS  praxis-gateway /ready returns ok"
  PASS=$((PASS + 1))
else
  echo "FAIL  praxis-gateway /ready: ${HEALTH}"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "===================================================================="
