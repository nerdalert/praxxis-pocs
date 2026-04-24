#!/bin/bash
# Validate all MaaS model paths routed through Praxis
#
# Tests:
#   - gpt-4o (ExternalModel → api.openai.com via Praxis)
#   - facebook/opt-125m (LLMInferenceService → in-cluster simulator)
#
# Usage:
#   ./scripts/validate-maas-all-models.sh

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
    echo "      body: ${body:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

TOKEN=$(oc whoami -t)

# =========================================================================
# Model 1: gpt-4o (ExternalModel → api.openai.com via Praxis)
# =========================================================================

echo "===================================================================="
echo "MODEL: gpt-4o (ExternalModel → api.openai.com via Praxis)"
echo "Path:  /llm/gpt-4o/v1/chat/completions"
echo "===================================================================="
echo ""

GPT_KEY=$(curl -sk -X POST "https://${GW_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"validate-gpt4o","subscription":"gpt-4o-subscription"}' \
  | jq -r '.key // empty')

if [ -z "$GPT_KEY" ]; then
  echo "SKIP  gpt-4o: could not mint MaaS API key"
  SKIP=$((SKIP + 1))
else
  echo "MaaS API key: ${GPT_KEY:0:20}..."
  echo ""

  RAW=$(curl -sk -w "\n%{http_code}" --max-time 15 \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $GPT_KEY" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}' 2>&1)
  CODE=$(echo "$RAW" | tail -1)
  BODY=$(echo "$RAW" | head -n -1)

  if [ "$CODE" = "200" ]; then
    echo "$BODY" | jq .
    echo ""
    echo "PASS  gpt-4o chat completion: HTTP ${CODE}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  gpt-4o chat completion: expected 200, got ${CODE}"
    echo "      body: ${BODY:0:200}"
    FAIL=$((FAIL + 1))
  fi

  check "gpt-4o bogus key rejected" 403 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer sk-oai-FAKE" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

  check "gpt-4o no auth rejected" 401 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'
fi

echo ""

# =========================================================================
# Model 2: facebook/opt-125m (LLMInferenceService → in-cluster simulator)
# =========================================================================

echo "===================================================================="
echo "MODEL: facebook/opt-125m (LLMInferenceService → in-cluster simulator)"
echo "Path:  /llm/facebook-opt-125m-cpu/v1/chat/completions"
echo "===================================================================="
echo ""

FB_KEY=$(curl -sk -X POST "https://${GW_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"validate-facebook","subscription":"facebook-opt-125m-cpu-subscription"}' \
  | jq -r '.key // empty')

if [ -z "$FB_KEY" ]; then
  echo "SKIP  facebook/opt-125m: could not mint MaaS API key"
  SKIP=$((SKIP + 1))
else
  echo "MaaS API key: ${FB_KEY:0:20}..."
  echo ""

  RAW=$(curl -sk -w "\n%{http_code}" --max-time 15 \
    "https://${GW_HOST}/llm/facebook-opt-125m-cpu/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $FB_KEY" \
    -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' 2>&1)
  CODE=$(echo "$RAW" | tail -1)
  BODY=$(echo "$RAW" | head -n -1)

  if [ "$CODE" = "200" ]; then
    echo "$BODY" | jq .
    echo ""
    echo "PASS  facebook/opt-125m chat completion: HTTP ${CODE}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  facebook/opt-125m chat completion: expected 200, got ${CODE}"
    echo "      body: ${BODY:0:200}"
    FAIL=$((FAIL + 1))
  fi

  check "facebook/opt-125m bogus key rejected" 403 "" \
    "https://${GW_HOST}/llm/facebook-opt-125m-cpu/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer sk-oai-FAKE" \
    -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hi"}]}'

  check "facebook/opt-125m no auth rejected" 401 "" \
    "https://${GW_HOST}/llm/facebook-opt-125m-cpu/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hi"}]}'
fi

echo ""

# =========================================================================
# Model listing
# =========================================================================

echo "===================================================================="
echo "MODEL LISTING"
echo "===================================================================="
echo ""

if [ -n "${GPT_KEY:-}" ]; then
  RAW=$(curl -sk -w "\n%{http_code}" --max-time 10 \
    "https://${GW_HOST}/v1/models" \
    -H "Authorization: Bearer $GPT_KEY" 2>&1)
  CODE=$(echo "$RAW" | tail -1)
  BODY=$(echo "$RAW" | head -n -1)

  if [ "$CODE" = "200" ]; then
    echo "$BODY" | jq -r '.data[].id' 2>/dev/null
    echo ""
    echo "PASS  model listing: HTTP ${CODE}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  model listing: expected 200, got ${CODE}"
    FAIL=$((FAIL + 1))
  fi
fi

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "===================================================================="
