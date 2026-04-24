#!/bin/bash
# MaaS + Praxis Integration — validate all paths
#
# Tests:
#   - BBR replacement: body-based model routing with body forwarding
#   - Provider gateway: external model via Praxis
#   - MaaS model path: gpt-4o with MaaS API key through Praxis
#
# Usage:
#   ./demos/maas-praxis/validate.sh

set -euo pipefail

GW_HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
echo "Gateway: $GW_HOST"
echo ""

PASS=0
FAIL=0
SKIP=0

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
    FAIL=$((FAIL + 1))
  fi
}

check_json() {
  local name="$1" expect_code="$2" jq_expr="$3"
  shift 3
  local response code body
  response=$(curl -sk -w "\n%{http_code}" --max-time 15 "$@" 2>&1)
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [ "$code" != "$expect_code" ]; then
    echo "FAIL  ${name}: expected ${expect_code}, got ${code}"
    FAIL=$((FAIL + 1))
    return
  fi

  if ! echo "$body" | jq -e "$jq_expr" >/dev/null 2>&1; then
    echo "FAIL  ${name}: HTTP ${code} but JSON check failed: ${jq_expr}"
    FAIL=$((FAIL + 1))
    return
  fi

  echo "PASS  ${name}: HTTP ${code}"
  PASS=$((PASS + 1))
}

# =========================================================================
# BBR Replacement — body-based model routing
# =========================================================================

PRAXIS_TOKEN=$(oc create token default -n llm \
  --audience=maas-default-gateway-sa 2>/dev/null || true)

if [ -z "$PRAXIS_TOKEN" ]; then
  echo "SKIP  BBR tests (could not create token)"
  SKIP=$((SKIP + 1))
else
  echo "===================================================================="
  echo "BBR REPLACEMENT — body-based model routing"
  echo "===================================================================="
  echo ""

  check_json "model=qwen routes and forwards body" 200 \
    '.model == "qwen" and .forwarded_model == "qwen" and .forwarded_prompt == "hello"' \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${PRAXIS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

  check_json "model=mistral routes and forwards body" 200 \
    '.model == "mistral" and .forwarded_model == "mistral" and .forwarded_prompt == "hello"' \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${PRAXIS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"mistral","messages":[{"role":"user","content":"hello"}]}'

  check "no auth rejected" 401 "" \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

  echo ""
fi

# =========================================================================
# Provider Gateway — external model via Praxis
# =========================================================================

if oc -n llm get deployment praxis-gateway &>/dev/null; then
  echo "===================================================================="
  echo "PROVIDER GATEWAY — gpt-4o via Praxis → OpenAI"
  echo "===================================================================="
  echo ""

  PRAXIS_TOKEN=${PRAXIS_TOKEN:-$(oc create token default -n llm \
    --audience=maas-default-gateway-sa 2>/dev/null || true)}

  check "chat completion via /praxis-gw/" 200 "chat.completion" \
    "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
    -H "Authorization: Bearer ${PRAXIS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}'

  check "provider route no auth rejected" 401 "" \
    "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

  echo ""
else
  echo "SKIP  Provider gateway (praxis-gateway not deployed)"
  SKIP=$((SKIP + 1))
fi

# =========================================================================
# MaaS Model Path — gpt-4o with MaaS API key
# =========================================================================

echo "===================================================================="
echo "MAAS MODEL PATH — gpt-4o with MaaS API key through Praxis"
echo "===================================================================="
echo ""

TOKEN=$(oc whoami -t)
KEY=$(curl -sk -X POST "https://${GW_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"validate","subscription":"gpt-4o-subscription"}' | jq -r '.key // empty')

if [ -z "$KEY" ]; then
  echo "SKIP  MaaS path (could not mint API key)"
  SKIP=$((SKIP + 1))
else
  echo "MaaS API key: ${KEY:0:20}..."

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
    echo "PASS  gpt-4o via MaaS API key: HTTP ${CODE}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  gpt-4o via MaaS API key: expected 200, got ${CODE}"
    FAIL=$((FAIL + 1))
  fi

  check "bogus key rejected" 403 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer sk-oai-FAKE" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

  check "no auth rejected" 401 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'
fi

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "===================================================================="
