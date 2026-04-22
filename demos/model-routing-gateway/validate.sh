#!/bin/bash
set -euo pipefail

GW_HOST=$(oc -n openshift-ingress get gateway maas-default-gateway \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN=$(oc create token default -n llm --audience=maas-default-gateway-sa)

echo "=== Model Routing Gateway Demo — Validation ==="
echo "Gateway: ${GW_HOST}"
echo ""

PASS=0
FAIL=0

check() {
  local name="$1" expect_code="$2" expect_body="${3:-}"
  shift 3
  local response code body
  response=$(curl -sk -w "\n%{http_code}" "$@")
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [ "$code" = "$expect_code" ]; then
    if [ -n "$expect_body" ] && ! echo "$body" | grep -q "$expect_body"; then
      echo "FAIL  ${name}: HTTP ${code} but body missing '${expect_body}'"
      echo "      body: ${body:0:200}"
      FAIL=$((FAIL + 1))
      return
    fi
    echo "PASS  ${name}: HTTP ${code}"
    if [ -n "$expect_body" ]; then
      echo "      ${body:0:120}..."
    fi
    PASS=$((PASS + 1))
  else
    echo "FAIL  ${name}: expected ${expect_code}, got ${code}"
    echo "      body: ${body:0:200}"
    FAIL=$((FAIL + 1))
  fi
}

# --- Provider routing test ---

check "chat completion via Praxis → OpenAI" 200 "chat.completion" \
  "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with the single word ok."}],"max_tokens":5}'

echo ""

# --- Auth tests ---

check "no auth returns 401" 401 "" \
  "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

check "bogus token returns 401" 401 "" \
  "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
  -H "Authorization: Bearer fake" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

# --- Health ---

echo ""
HEALTH=$(oc -n llm exec deployment/praxis-gateway -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/ready 2>/dev/null || echo "UNREACHABLE")
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  echo "PASS  admin /ready returns ok"
  PASS=$((PASS + 1))
else
  echo "FAIL  admin /ready: ${HEALTH}"
  FAIL=$((FAIL + 1))
fi

# --- Praxis logs ---

echo ""
echo "=== Recent Praxis gateway access logs ==="
oc -n llm logs deployment/praxis-gateway --tail=5 2>&1 | grep access || echo "(no access logs)"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
