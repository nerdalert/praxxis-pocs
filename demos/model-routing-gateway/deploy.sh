#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Model Routing Gateway Demo ==="
echo ""

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: OPENAI_API_KEY is not set"
  echo "Usage: OPENAI_API_KEY='sk-...' $0"
  exit 1
fi

# Ensure namespace
oc create namespace llm 2>/dev/null || true

# Apply manifests
echo "Deploying manifests..."
oc apply -f "${SCRIPT_DIR}/manifests.yaml"

# Patch ConfigMap with real API key
echo "Injecting provider credentials..."
oc -n llm get configmap praxis-gateway-config -o jsonpath='{.data.config\.yaml}' \
  | sed "s|OPENAI_API_KEY_PLACEHOLDER|${OPENAI_API_KEY}|g" \
  > /tmp/praxis-gateway-config-resolved.yaml

oc -n llm create configmap praxis-gateway-config \
  --from-file=config.yaml=/tmp/praxis-gateway-config-resolved.yaml \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/praxis-gateway-config-resolved.yaml

# Restart to pick up the config with credentials
oc -n llm rollout restart deployment/praxis-gateway
echo "Waiting for Praxis gateway..."
oc -n llm rollout status deployment/praxis-gateway --timeout=120s

echo ""
echo "=== Deployed ==="
echo ""
echo "Run: ${SCRIPT_DIR}/validate.sh"
