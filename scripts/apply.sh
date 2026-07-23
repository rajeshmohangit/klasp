#!/usr/bin/env bash
set -euo pipefail

# apply.sh — Bootstrap deployer into a Kubernetes cluster
#
# This is the "publish + first deploy" step run from the klasp-deployer image.
# It renders the base templates (CronJobs, ConfigMaps) and applies them.
# After this, in-cluster CronJobs reconcile autonomously.
#
# Requires: gomplate, kubectl, yq (all present in klasp-deployer image)
#
# Usage: ./scripts/apply.sh <env-name> [output-dir]
#   ENV_NAME — matches environments/<env>.yaml
#   OUTPUT_DIR — root of generated outputs (default: current working dir or /opt/klasp)

ENV_NAME="${1:?Usage: apply.sh <env-name> [output-dir]}"
OUTPUT_DIR="${2:-${OPERATOR_HOME:-.}}"

# Resolve paths — prefer repo-root environments/ (user-edited source of truth);
# fall back to $OUTPUT_DIR/environments/ (in-image flat layout).
if [ -f "environments/${ENV_NAME}.yaml" ]; then
  ENV_FILE="environments/${ENV_NAME}.yaml"
elif [ -f "$OUTPUT_DIR/environments/${ENV_NAME}.yaml" ]; then
  ENV_FILE="$OUTPUT_DIR/environments/${ENV_NAME}.yaml"
else
  echo "ERROR: environments/${ENV_NAME}.yaml not found"
  exit 1
fi

if [ -d "$OUTPUT_DIR/base" ]; then
  BASE_DIR="$OUTPUT_DIR/base"
elif [ -d "base" ]; then
  BASE_DIR="base"
else
  echo "ERROR: base/ directory not found"
  exit 1
fi

RENDER_DIR="$OUTPUT_DIR/render/${ENV_NAME}"

# Inject mode from OPERATOR_MODE env (baked into image at build time)
OPERATOR_MODE="${OPERATOR_MODE:-online}"
if ! grep -q "^mode:" "$ENV_FILE"; then
  sed -i'' -e "/^platform:/a\\
mode: ${OPERATOR_MODE}" "$ENV_FILE"
fi

# Read key fields from env file
RELEASE=$(yq '.release' "$ENV_FILE")
RESOURCE_TIER=$(yq '.resource_tier // "default"' "$ENV_FILE")
REGISTRY_NS=$(yq '.registry_namespace // "operator-registry"' "$ENV_FILE")
ORCHESTRATION_NS="orchestration-${ENV_NAME}"

# Resolve presets and golden-config paths
if [ -d "$OUTPUT_DIR/presets" ]; then
  PRESETS_DIR="$OUTPUT_DIR/presets"
elif [ -d "output/presets" ]; then
  PRESETS_DIR="output/presets"
else
  echo "ERROR: presets/ directory not found"
  exit 1
fi

if [ -d "$OUTPUT_DIR/golden-configuration" ]; then
  GOLDEN_DIR="$OUTPUT_DIR/golden-configuration"
elif [ -d "output/golden-configuration" ]; then
  GOLDEN_DIR="output/golden-configuration"
else
  echo "ERROR: golden-configuration/ directory not found"
  exit 1
fi

BUILD_PRESET="$PRESETS_DIR/build/${RELEASE}.yaml"
RESOURCE_PRESET="$PRESETS_DIR/resource/${RELEASE}/${RESOURCE_TIER}.yaml"

if [ ! -f "$BUILD_PRESET" ]; then
  echo "ERROR: $BUILD_PRESET not found"
  exit 1
fi
if [ ! -f "$RESOURCE_PRESET" ]; then
  echo "ERROR: $RESOURCE_PRESET not found"
  exit 1
fi

# Convert to absolute paths before cd
ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
BASE_DIR="$(cd "$BASE_DIR" && pwd)"
BUILD_PRESET="$(cd "$(dirname "$BUILD_PRESET")" && pwd)/$(basename "$BUILD_PRESET")"
RESOURCE_PRESET="$(cd "$(dirname "$RESOURCE_PRESET")" && pwd)/$(basename "$RESOURCE_PRESET")"
PRESETS_DIR="$(cd "$PRESETS_DIR" && pwd)"
GOLDEN_DIR="$(cd "$GOLDEN_DIR" && pwd)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
RENDER_DIR="$OUTPUT_DIR/render/${ENV_NAME}"

echo "=== Applying KLASP deployer to cluster ==="
echo "  Environment: $ENV_NAME"
echo "  Release: $RELEASE"
echo "  Resource tier: $RESOURCE_TIER"
echo "  Registry namespace: $REGISTRY_NS"
echo "  Orchestration namespace: $ORCHESTRATION_NS"
echo ""

mkdir -p "$RENDER_DIR"

# 1. Create namespaces
echo "  [1/4] Creating namespaces..."
kubectl create namespace "$REGISTRY_NS" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
kubectl create namespace "$ORCHESTRATION_NS" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

# Create app namespaces
for ns_key in $(yq -r 'to_entries[] | select(.key | test("_orchestration_namespace$")) | .value' "$ENV_FILE"); do
  kubectl create namespace "$ns_key" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
done
echo "    OK"

# 2. Render and apply registry kustomization (presets + golden-config as ConfigMaps)
echo "  [2/4] Publishing presets and golden-config..."
REGISTRY_RENDER_DIR="$OUTPUT_DIR/render/registry"
rm -rf "$REGISTRY_RENDER_DIR"
mkdir -p "$REGISTRY_RENDER_DIR"

# Copy presets and golden-config into render dir (kustomize requires files in or below its root)
cp -r "$PRESETS_DIR" "$REGISTRY_RENDER_DIR/presets"
cp -r "$GOLDEN_DIR" "$REGISTRY_RENDER_DIR/golden-configuration"

cd "$OUTPUT_DIR"
gomplate \
  -d "env=$ENV_FILE" \
  -d "build=$BUILD_PRESET" \
  -f "$BASE_DIR/registry-kustomization.yaml.tmpl" \
  -o "$REGISTRY_RENDER_DIR/kustomization.yaml"

kubectl apply -k "$REGISTRY_RENDER_DIR" 2>/dev/null || \
  kubectl kustomize "$REGISTRY_RENDER_DIR" | kubectl apply -f -

# Publish local chart tarballs as ConfigMaps (for charts without a remote repo)
CHARTS_DIR="${OUTPUT_DIR}/../charts"
[ -d "$CHARTS_DIR" ] || CHARTS_DIR="${OUTPUT_DIR}/charts"
if [ -d "$CHARTS_DIR" ]; then
  for app_key in $(yq -r 'to_entries[] | select(.key | test("_orchestration_mode$")) | .key | sub("_orchestration_mode$"; "")' "$ENV_FILE"); do
    chart_repo=$(yq -r ".${app_key}_helm_chart_repo // \"\"" "$BUILD_PRESET" 2>/dev/null || echo "")
    if [ "$chart_repo" = "local" ]; then
      chart_name=$(yq -r ".${app_key}_helm_chart // \"\"" "$BUILD_PRESET")
      chart_version=$(yq -r ".${app_key}_helm_chart_version // \"\"" "$BUILD_PRESET")
      chart_file="$CHARTS_DIR/${chart_name}-${chart_version}.tgz"
      if [ -f "$chart_file" ]; then
        app_name=$(echo "$app_key" | tr '_' '-')
        echo "    Publishing local chart: $chart_file → localchart-${app_name}"
        kubectl create configmap "localchart-${app_name}" \
          --from-file="chart.tgz=${chart_file}" \
          --namespace "$REGISTRY_NS" \
          --dry-run=client -o yaml | kubectl apply -f -
      fi
    fi
  done
fi
echo "    OK"

# 3. Render helm-cronjob and main kustomization
echo "  [3/4] Rendering deployer CronJobs..."
ORCHESTRATION_RENDER_DIR="$OUTPUT_DIR/render/orchestration"
rm -rf "$ORCHESTRATION_RENDER_DIR"
mkdir -p "$ORCHESTRATION_RENDER_DIR"

# Copy env file into render dir for kustomize configMapGenerator
mkdir -p "$ORCHESTRATION_RENDER_DIR/environments"
cp "$ENV_FILE" "$ORCHESTRATION_RENDER_DIR/environments/"

gomplate \
  -d "env=$ENV_FILE" \
  -d "build=$BUILD_PRESET" \
  -f "$BASE_DIR/helm-cronjob.yaml.tmpl" \
  -o "$ORCHESTRATION_RENDER_DIR/helm-cronjob.yaml"

gomplate \
  -d "env=$ENV_FILE" \
  -d "build=$BUILD_PRESET" \
  -f "$BASE_DIR/kustomization.yaml.tmpl" \
  -o "$ORCHESTRATION_RENDER_DIR/kustomization.yaml"
echo "    OK"

# 4. Apply orchestration kustomization (RBAC + CronJobs + evars ConfigMap)
echo "  [4/4] Applying deployer CronJobs..."
kubectl apply -k "$ORCHESTRATION_RENDER_DIR" 2>/dev/null || \
  kubectl kustomize "$ORCHESTRATION_RENDER_DIR" | kubectl apply -f -
echo "    OK"

echo ""
echo "=== Bootstrap complete ==="
echo "  Deployer CronJobs created in: $ORCHESTRATION_NS"
echo "  Presets + golden-config published to: $REGISTRY_NS"
echo ""
echo "  CronJobs will reconcile on their configured schedule."
echo "  To trigger immediate deployment:"
echo "    kubectl create job --from=cronjob/<app>-deployer <app>-manual -n $ORCHESTRATION_NS"
