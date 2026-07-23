#!/usr/bin/env bash
set -euo pipefail

# publish-binaries.sh — Push orchestration binaries as OCI artifacts
#
# The in-cluster CronJob's fetch-binaries init container pulls sops and gomplate
# from the registry as OCI blob layers. This script publishes them.
#
# Requires: oras (or crane), curl
#
# Usage: ./scripts/publish-binaries.sh <registry> [output-dir]
#   REGISTRY — e.g., ghcr.io/rajeshmohangit/framework
#   OUTPUT_DIR — root containing oci/sbom.yaml

REGISTRY="${1:?Usage: publish-binaries.sh <registry> [output-dir]}"
OUTPUT_DIR="${2:-${OPERATOR_HOME:-.}}"

SBOM_FILE="$OUTPUT_DIR/oci/sbom.yaml"
ARTIFACTS_DIR="$OUTPUT_DIR/oci/artifacts/embed/binaries"

if [ ! -f "$SBOM_FILE" ]; then
  echo "ERROR: $SBOM_FILE not found — run emit-oci first"
  exit 1
fi

BINARIES_TO_PUBLISH="sops gomplate"

echo "=== Publishing binaries as OCI artifacts ==="
echo "  Registry: $REGISTRY"
echo ""

for bin_name in $BINARIES_TO_PUBLISH; do
  tag=$(yq -r ".embed[] | select(.binaries != null) | .binaries[] | select(.name == \"$bin_name\") | .tag" "$SBOM_FILE")
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    echo "  SKIP: $bin_name (not found in sbom)"
    continue
  fi

  bin_file="$ARTIFACTS_DIR/$bin_name"
  if [ ! -f "$bin_file" ]; then
    echo "  ERROR: $bin_file not found — run 'task -d oci pull-binaries' first"
    continue
  fi

  ref="$REGISTRY/binaries-${bin_name}:${tag}"
  echo "  Publishing: $ref"

  if command -v oras >/dev/null 2>&1; then
    oras push "$ref" \
      --artifact-type application/octet-stream \
      "$bin_file:application/octet-stream"
  else
    # Fallback: use crane with a tarball
    tmptar=$(mktemp)
    tar -czf "$tmptar" -C "$(dirname "$bin_file")" "$bin_name"
    crane push "$tmptar" "$ref"
    rm -f "$tmptar"
  fi

  echo "    OK: $ref"
done

echo ""
echo "=== Done ==="
echo "  Published binaries are referenced by fetch-binaries init container in CronJobs."
echo "  Build preset must include: sops_tag and gomplate_tag fields."
