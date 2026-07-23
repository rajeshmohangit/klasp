#!/usr/bin/env bash
set -euo pipefail

# seed-registry.sh — Push artifacts to OKD internal registry via port-forward
#
# Uses the deployer pattern:
#   1. Port-forward to image-registry.openshift-image-registry.svc:5000
#   2. Authenticate with registry-pusher SA token
#   3. Push binaries (as tar.gz OCI blobs via crane)
#   4. Push charts (as OCI helm artifacts via skopeo)
#   5. Push images (as OCI layout via skopeo)
#
# Prerequisites:
#   - kubectl access to OKD cluster (KUBECONFIG set)
#   - registry-pusher SA with system:image-builder role in target namespace
#   - crane, skopeo on PATH
#   - Artifacts pulled locally (task -d output/oci pull)
#
# Usage: ./scripts/seed-registry.sh <env-name> [output-dir]

ENV_NAME="${1:?Usage: seed-registry.sh <env-name> [output-dir]}"
OUTPUT_DIR="${2:-./output}"

# Resolve env file
if [ -f "environments/${ENV_NAME}.yaml" ]; then
  ENV_FILE="environments/${ENV_NAME}.yaml"
elif [ -f "$OUTPUT_DIR/environments/${ENV_NAME}.yaml" ]; then
  ENV_FILE="$OUTPUT_DIR/environments/${ENV_NAME}.yaml"
else
  echo "ERROR: environments/${ENV_NAME}.yaml not found"
  exit 1
fi

SBOM_FILE="$OUTPUT_DIR/oci/sbom.yaml"
ARTIFACTS_DIR="$OUTPUT_DIR/oci/artifacts"

if [ ! -f "$SBOM_FILE" ]; then
  echo "ERROR: $SBOM_FILE not found — run generate first"
  exit 1
fi

if [ ! -d "$ARTIFACTS_DIR/embed" ]; then
  echo "ERROR: $ARTIFACTS_DIR/embed not found — run 'task -d output/oci pull' first"
  exit 1
fi

# Read config from env file
REGISTRY_NS=$(yq '.registry_namespace // "operator-registry"' "$ENV_FILE")

# OKD registry port-forward settings
OKD_REGISTRY_NS="openshift-image-registry"
OKD_REGISTRY_SVC="image-registry"
OKD_REGISTRY_PORT="5000"
OKD_LOCAL_PORT="5995"

# --- Helpers ---
log_info()  { echo "  [INFO] $*"; }
log_warn()  { echo "  [WARN] $*"; }
log_error() { echo "  [ERROR] $*" >&2; }

start_port_forward() {
  lsof -ti :${OKD_LOCAL_PORT} | xargs kill 2>/dev/null || true
  sleep 1

  kubectl port-forward -n ${OKD_REGISTRY_NS} svc/${OKD_REGISTRY_SVC} ${OKD_LOCAL_PORT}:${OKD_REGISTRY_PORT} --address 0.0.0.0 > /tmp/seed-registry-pf.log 2>&1 &
  PF_PID=$!

  local attempt=1
  while [ $attempt -le 5 ]; do
    sleep 2
    if grep -q "Forwarding from" /tmp/seed-registry-pf.log 2>/dev/null; then
      log_info "Port-forward established (PID: ${PF_PID})"
      return 0
    fi
    log_warn "Waiting for port-forward... (attempt $attempt/5)"
    attempt=$((attempt + 1))
  done

  log_error "Failed to establish port-forward"
  cat /tmp/seed-registry-pf.log 2>/dev/null
  return 1
}

cleanup() {
  if [ -n "${PF_PID:-}" ]; then
    kill $PF_PID 2>/dev/null || true
    sleep 1
    kill -9 $PF_PID 2>/dev/null || true
  fi
  rm -rf "${DOCKER_CONFIG:-}" 2>/dev/null || true
}
trap cleanup EXIT

# --- Main ---
echo "=== Seeding OKD registry ==="
echo "  Environment: $ENV_NAME"
echo "  Registry namespace: $REGISTRY_NS"
echo "  SBOM: $SBOM_FILE"
echo ""

# Ensure namespace and SA exist
kubectl get namespace "$REGISTRY_NS" >/dev/null 2>&1 || kubectl create namespace "$REGISTRY_NS"
kubectl get sa registry-pusher -n "$REGISTRY_NS" >/dev/null 2>&1 || \
  kubectl create sa registry-pusher -n "$REGISTRY_NS"

# Ensure image-builder role for the SA
kubectl get rolebinding registry-pusher-image-builder -n "$REGISTRY_NS" >/dev/null 2>&1 || \
  kubectl create rolebinding registry-pusher-image-builder \
    --clusterrole=system:image-builder \
    --serviceaccount="${REGISTRY_NS}:registry-pusher" \
    -n "$REGISTRY_NS"

# Grant image-puller to orchestration and app namespaces
ORCHESTRATION_NS="orchestration-${ENV_NAME}"
kubectl get namespace "$ORCHESTRATION_NS" >/dev/null 2>&1 || kubectl create namespace "$ORCHESTRATION_NS"
kubectl get rolebinding "image-puller-${ORCHESTRATION_NS}" -n "$REGISTRY_NS" >/dev/null 2>&1 || \
  kubectl create rolebinding "image-puller-${ORCHESTRATION_NS}" \
    --clusterrole=system:image-puller \
    --group="system:serviceaccounts:${ORCHESTRATION_NS}" \
    -n "$REGISTRY_NS"

# Grant image-puller to app namespaces
for ns_key in $(yq -r 'to_entries[] | select(.key | test("_orchestration_namespace$")) | .value' "$ENV_FILE"); do
  kubectl get namespace "$ns_key" >/dev/null 2>&1 || kubectl create namespace "$ns_key"
  kubectl get rolebinding "image-puller-${ns_key}" -n "$REGISTRY_NS" >/dev/null 2>&1 || \
    kubectl create rolebinding "image-puller-${ns_key}" \
      --clusterrole=system:image-puller \
      --group="system:serviceaccounts:${ns_key}" \
      -n "$REGISTRY_NS"
done

# Create registry-token secret for CronJob init container (airgap mode)
# The helm-deployer SA in the orchestration namespace needs a token to pull from the internal registry
DEPLOYER_SA="helm-deployer-${ENV_NAME}"
kubectl get sa "$DEPLOYER_SA" -n "$ORCHESTRATION_NS" >/dev/null 2>&1 || \
  kubectl create sa "$DEPLOYER_SA" -n "$ORCHESTRATION_NS"
DEPLOYER_TOKEN=$(kubectl create token "$DEPLOYER_SA" -n "$ORCHESTRATION_NS" --duration=87600h 2>/dev/null || echo "")
if [ -n "$DEPLOYER_TOKEN" ]; then
  kubectl create secret generic registry-token \
    --from-literal=username="${DEPLOYER_SA}" \
    --from-literal=token="${DEPLOYER_TOKEN}" \
    -n "$ORCHESTRATION_NS" --dry-run=client -o yaml | kubectl apply -f -
  log_info "registry-token secret created/updated in $ORCHESTRATION_NS"
fi

# Start port-forward
start_port_forward

TARGET="localhost:${OKD_LOCAL_PORT}/${REGISTRY_NS}"
TOKEN=$(kubectl create token registry-pusher -n "${REGISTRY_NS}" --duration=3600s)

# Set up auth
DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG
export HELM_REGISTRY_CONFIG="$DOCKER_CONFIG/config.json"
AUTHFILE="$DOCKER_CONFIG/config.json"
AUTH=$(echo -n "registry-pusher:${TOKEN}" | base64 | tr -d '\n')
echo "{\"auths\":{\"localhost:${OKD_LOCAL_PORT}\":{\"auth\":\"${AUTH}\"}}}" > "$AUTHFILE"

# --- Push binaries ---
echo ""
echo "=== Publishing binaries ==="
entries=$(yq -r '
  .embed[]
  | select(.binaries != null and (.binaries | length) > 0)
  | .binaries[]
  | "\(.name) \(.tag)"
' "$SBOM_FILE" 2>/dev/null | grep '[a-zA-Z0-9]' || true)

if [ -n "$entries" ]; then
  echo "$entries" | while read -r name tag; do
    bin_file="${ARTIFACTS_DIR}/embed/binaries/$name"
    if [ ! -f "$bin_file" ]; then echo "  SKIP: $bin_file not found"; continue; fi

    imagestream="binaries-${name}"
    kubectl create imagestream "$imagestream" -n "$REGISTRY_NS" 2>/dev/null || true

    if crane digest "${TARGET}/${imagestream}:${tag}" --insecure >/dev/null 2>&1; then
      echo "  SKIP: ${imagestream}:${tag} already exists"
      continue
    fi

    tgz=$(mktemp)
    tar -czf "$tgz" -C "$(dirname "$bin_file")" "$(basename "$bin_file")"

    log_info "Pushing ${imagestream}:${tag} ($(du -h "$tgz" | cut -f1) tar.gz)"
    crane append -f "$tgz" -t "${TARGET}/${imagestream}:${tag}" --insecure --platform linux/amd64
    rm -f "$tgz"
  done
else
  echo "  No binaries to publish"
fi

# --- Push charts ---
echo ""
echo "=== Publishing charts ==="
entries=$(yq -r '
  .embed[]
  | select(.charts != null and (.charts | length) > 0)
  | .charts[]
  | "\(.name) \(.chart) \(.version)"
' "$SBOM_FILE" 2>/dev/null | grep '[a-zA-Z0-9]' || true)

if [ -n "$entries" ]; then
  echo "$entries" | while read -r name chart version; do
    chart_file=$(ls ${ARTIFACTS_DIR}/embed/charts/*/${chart}-${version}.tgz 2>/dev/null | head -1)
    if [ -z "$chart_file" ]; then echo "  SKIP: chart ${chart}-${version}.tgz not found"; continue; fi

    imagestream="charts-${chart}"
    kubectl create imagestream "$imagestream" -n "$REGISTRY_NS" 2>/dev/null || true

    if crane digest "${TARGET}/${imagestream}:${version}" --insecure >/dev/null 2>&1; then
      echo "  SKIP: ${imagestream}:${version} already exists"
      continue
    fi

    log_info "Pushing ${imagestream}:${version}"
    oci_dir=$(mktemp -d)
    mkdir -p "$oci_dir/blobs/sha256"
    CHART_DIGEST=$(sha256sum "$chart_file" | cut -d' ' -f1)
    CHART_SIZE=$(wc -c < "$chart_file" | tr -d ' ')
    cp "$chart_file" "$oci_dir/blobs/sha256/$CHART_DIGEST"
    CONFIG='{}'
    CONFIG_DIGEST=$(echo -n "$CONFIG" | sha256sum | cut -d' ' -f1)
    CONFIG_SIZE=$(echo -n "$CONFIG" | wc -c | tr -d ' ')
    echo -n "$CONFIG" > "$oci_dir/blobs/sha256/$CONFIG_DIGEST"
    MANIFEST="{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"artifactType\":\"application/vnd.cncf.helm.config.v1+json\",\"config\":{\"mediaType\":\"application/vnd.cncf.helm.config.v1+json\",\"digest\":\"sha256:${CONFIG_DIGEST}\",\"size\":${CONFIG_SIZE}},\"layers\":[{\"mediaType\":\"application/vnd.cncf.helm.chart.content.v1.tar+gzip\",\"digest\":\"sha256:${CHART_DIGEST}\",\"size\":${CHART_SIZE},\"annotations\":{\"org.opencontainers.image.title\":\"${chart}-${version}.tgz\"}}]}"
    MANIFEST_DIGEST=$(echo -n "$MANIFEST" | sha256sum | cut -d' ' -f1)
    MANIFEST_SIZE=$(echo -n "$MANIFEST" | wc -c | tr -d ' ')
    echo -n "$MANIFEST" > "$oci_dir/blobs/sha256/$MANIFEST_DIGEST"
    echo "{\"schemaVersion\":2,\"manifests\":[{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:${MANIFEST_DIGEST}\",\"size\":${MANIFEST_SIZE}}]}" > "$oci_dir/index.json"
    echo '{"imageLayoutVersion":"1.0.0"}' > "$oci_dir/oci-layout"
    skopeo --insecure-policy copy --dest-tls-verify=false --dest-authfile "$AUTHFILE" "oci:${oci_dir}" "docker://${TARGET}/${imagestream}:${version}"
    rm -rf "$oci_dir"
  done
else
  echo "  No charts to publish"
fi

# --- Push images ---
echo ""
echo "=== Publishing images ==="
entries=$(yq -r '
  .embed[]
  | select(.images != null and (.images | length) > 0)
  | .name as $app
  | .images[]
  | "\($app) \(.name) \(.tag)"
' "$SBOM_FILE" 2>/dev/null | grep '[a-zA-Z0-9]' || true)

if [ -n "$entries" ]; then
  echo "$entries" | while read -r app name tag; do
    image_dir="${ARTIFACTS_DIR}/embed/images/$app/$name/$tag"
    if [ ! -d "$image_dir" ]; then echo "  SKIP: $image_dir not found"; continue; fi

    imagestream="images-${name}"
    kubectl create imagestream "$imagestream" -n "$REGISTRY_NS" 2>/dev/null || true

    LOCAL_DIGEST=$(grep -o '"sha256:[^"]*' "${image_dir}/index.json" | head -1 | tr -d '"')
    REMOTE_DIGEST=$(crane digest "${TARGET}/${imagestream}:${tag}" --insecure 2>/dev/null || true)
    if [ -n "$LOCAL_DIGEST" ] && [ "$LOCAL_DIGEST" = "$REMOTE_DIGEST" ]; then
      echo "  SKIP: ${imagestream}:${tag} digest matches ($LOCAL_DIGEST)"
      continue
    fi

    log_info "Pushing ${imagestream}:${tag}"
    MANIFEST_COUNT=$(jq '.manifests | length' "${image_dir}/index.json")
    if [ "$MANIFEST_COUNT" -gt 1 ]; then
      tmp_oci=$(mktemp -d)
      cp -a "${image_dir}/oci-layout" "$tmp_oci/"
      cp -a "${image_dir}/blobs" "$tmp_oci/"
      jq '{schemaVersion: .schemaVersion, manifests: [.manifests[0]]}' "${image_dir}/index.json" > "$tmp_oci/index.json"
      skopeo --insecure-policy copy --dest-tls-verify=false --dest-authfile "$AUTHFILE" \
        --override-arch amd64 --override-os linux \
        "oci:${tmp_oci}" \
        "docker://${TARGET}/${imagestream}:${tag}"
      rm -rf "$tmp_oci"
    else
      skopeo --insecure-policy copy --dest-tls-verify=false --dest-authfile "$AUTHFILE" \
        --override-arch amd64 --override-os linux \
        "oci:${image_dir}" \
        "docker://${TARGET}/${imagestream}:${tag}"
    fi
  done
else
  echo "  No images to publish"
fi


echo ""
echo "=== Seed complete ==="
echo "  Artifacts pushed to: image-registry.openshift-image-registry.svc:5000/${REGISTRY_NS}"
echo "  Internal pull path:  image-registry.openshift-image-registry.svc:5000/${REGISTRY_NS}/<imagestream>:<tag>"
