#!/bin/bash
# MaaS + Praxis Integration — deploy all components
#
# Deploys:
#   - BBR replacement: mock backends + Praxis with model_to_header routing
#   - Provider gateway: Praxis with external TLS to OpenAI
#
# Usage:
#   OPENAI_API_KEY='sk-...' ./demos/maas-praxis/deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: OPENAI_API_KEY is not set"
  echo "Usage: OPENAI_API_KEY='sk-...' $0"
  exit 1
fi

echo "===================================================================="
echo "MaaS + Praxis Integration — Deploy"
echo "===================================================================="
echo ""

# Ensure namespace without Istio sidecar injection
oc create namespace llm 2>/dev/null || true
oc label namespace llm istio-injection- 2>/dev/null || true

# --- BBR Replacement ---

echo "--- BBR Replacement (mock backend routing) ---"
oc apply -f "${SCRIPT_DIR}/manifests/bbr-replacement.yaml"

echo "Waiting for mock backends..."
oc -n llm rollout status deployment/echo-qwen --timeout=120s
oc -n llm rollout status deployment/echo-mistral --timeout=120s

QWEN_IP=$(oc -n llm get svc echo-qwen -o jsonpath='{.spec.clusterIP}')
MISTRAL_IP=$(oc -n llm get svc echo-mistral -o jsonpath='{.spec.clusterIP}')
echo "Backend IPs: qwen=${QWEN_IP} mistral=${MISTRAL_IP}"

oc -n llm get configmap praxis-config -o jsonpath='{.data.config\.yaml}' \
  | sed "s/QWEN_CLUSTER_IP/${QWEN_IP}/g" \
  | sed "s/MISTRAL_CLUSTER_IP/${MISTRAL_IP}/g" \
  > /tmp/praxis-config-resolved.yaml

oc -n llm create configmap praxis-config \
  --from-file=config.yaml=/tmp/praxis-config-resolved.yaml \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/praxis-config-resolved.yaml

oc -n llm rollout restart deployment/praxis
echo "Waiting for Praxis (BBR)..."
oc -n llm rollout status deployment/praxis --timeout=120s
echo ""

# --- Provider Gateway ---

echo "--- Provider Gateway (external model routing) ---"
oc apply -f "${SCRIPT_DIR}/manifests/provider-gateway.yaml"

CONFIG=$(oc -n llm get configmap praxis-gateway-config -o jsonpath='{.data.config\.yaml}')
CONFIG="${CONFIG//OPENAI_API_KEY_PLACEHOLDER/$OPENAI_API_KEY}"
printf '%s' "$CONFIG" > /tmp/praxis-gateway-config-resolved.yaml

oc -n llm create configmap praxis-gateway-config \
  --from-file=config.yaml=/tmp/praxis-gateway-config-resolved.yaml \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/praxis-gateway-config-resolved.yaml

oc -n llm rollout restart deployment/praxis-gateway
echo "Waiting for Praxis (gateway)..."
oc -n llm rollout status deployment/praxis-gateway --timeout=120s
echo ""

# --- Patch MaaS gpt-4o HTTPRoute to use Praxis ---

echo "--- Patching gpt-4o HTTPRoute to Praxis backend ---"
if oc -n llm get httproute gpt-4o &>/dev/null; then
  oc -n llm patch httproute gpt-4o --type='json' -p='[
    {"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"praxis-gateway"},
    {"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":8080},
    {"op":"replace","path":"/spec/rules/1/backendRefs/0/name","value":"praxis-gateway"},
    {"op":"replace","path":"/spec/rules/1/backendRefs/0/port","value":8080}
  ]'
  echo "gpt-4o HTTPRoute patched to praxis-gateway:8080"
else
  echo "WARN: gpt-4o HTTPRoute not found — deploy ExternalModel first (see docs/install.md §5)"
fi
echo ""

echo "===================================================================="
echo "Deployed. Run: ${SCRIPT_DIR}/validate.sh"
echo "===================================================================="
