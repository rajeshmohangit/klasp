#!/usr/bin/env bash
set -euo pipefail

# validate.sh — Validate that a generated golden-config template renders valid YAML
#
# Strategy:
#   1. Check balanced template delimiters
#   2. Generate stub evars + resource + build data from fields.json
#   3. Render the template with gomplate using stubs
#   4. Verify the rendered output is valid YAML
#
# Usage: ./scripts/validate.sh <app-name> [output-dir]

APP_NAME="${1:?Usage: validate.sh <app-name> [output-dir]}"
OUTPUT_DIR="${2:-./output}"

GC_FILE="$OUTPUT_DIR/golden-configuration/$APP_NAME/values.yaml.tmpl"
FIELDS_FILE="$OUTPUT_DIR/${APP_NAME}-fields.json"

if [ ! -f "$GC_FILE" ]; then
  echo "ERROR: $GC_FILE not found — run generate first"
  exit 1
fi
if [ ! -f "$FIELDS_FILE" ]; then
  echo "ERROR: $FIELDS_FILE not found — run analyze first"
  exit 1
fi

echo "  Validating: $GC_FILE"

# 1. Check balanced delimiters (warning only — charts may have template examples in comments)
OPEN=$(grep -o '{{' "$GC_FILE" | wc -l | tr -d ' ')
CLOSE=$(grep -o '}}' "$GC_FILE" | wc -l | tr -d ' ')
if [ "$OPEN" -ne "$CLOSE" ]; then
  echo "  WARN: Unbalanced delimiters ($OPEN opens, $CLOSE closes) — may be due to chart comments"
else
  echo "  OK: Balanced delimiters ($OPEN expressions)"
fi

# 2. Generate stub data from fields.json
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# Evars stub (JSON — only env-varying fields: dynamic excluding images/replicas, plus sensitive)
jq -r '
  [.[] | select(.classification == "dynamic" or .classification == "sensitive")
    | select(.type != "image_registry" and .type != "image_repository" and .type != "image_tag")
    | select((.type == "integer" and (.key | endswith("_replicas"))) | not)]
  | map({(.key): (.value // "placeholder")})
  | add // {}
  | . + {"env": "validation", "node_selector_key": "environment", "release": "test", "resource_tier": "default"}
' "$FIELDS_FILE" > "$STUB_DIR/evars.json"

# Resource stub (JSON — cpu/memory + replicas)
jq -r '
  [.[] | select(
    .classification == "resource" or
    (.classification == "dynamic" and .type == "integer" and (.key | endswith("_replicas")))
  )]
  | map({(.key): (.value // "1")})
  | add // {}
' "$FIELDS_FILE" > "$STUB_DIR/resource.json"

# Build stub (JSON — image fields + chart metadata)
jq -r '
  [.[] | select(.type == "image_registry" or .type == "image_repository" or .type == "image_tag")]
  | map({(.key): (.value // "placeholder")})
  | add // {}
' "$FIELDS_FILE" > "$STUB_DIR/build.json"

# 3. Render with gomplate
# Strip Helm template expressions that aren't our gomplate code.
# Our gomplate expressions always contain $e or $r or $b or $app_key or $nsk or datasource or getenv.
# Helm templates use .Values, .Release, .Chart, range, define, include, etc.
# Strategy: remove {{ ... }} sequences inline (not whole lines) to preserve YAML block scalars.
PATCHED="$STUB_DIR/patched.tmpl"
perl -pe '
  # For lines with {{ that are NOT our gomplate code: remove the template expressions inline
  if (/\{\{/ && !/\$e\b|\$r\b|\$b\b|\$app_key|\$nsk|datasource\s+"|getenv/) {
    # Remove {{- ... -}}, {{- ... }}, {{ ... -}}, {{ ... }} sequences
    s/\{\{-?\s*.*?\s*-?\}\}//g;
    # If the line is now only whitespace/empty, make it a blank line
    if (/^\s*$/) { $_ = "\n"; }
  }
' "$GC_FILE" > "$PATCHED"

RENDERED="$STUB_DIR/rendered-values.yaml"
APP_NAME="$APP_NAME" \
gomplate \
  -d "env=$STUB_DIR/evars.json" \
  -d "resource=$STUB_DIR/resource.json" \
  -d "build=$STUB_DIR/build.json" \
  -f "$PATCHED" \
  -o "$RENDERED" 2>"$STUB_DIR/gomplate.err" || {
    echo "  FAIL: gomplate render failed:"
    cat "$STUB_DIR/gomplate.err" | sed 's/^/    /'
    exit 1
  }

# 4. Validate rendered output is valid YAML
if yq eval '.' "$RENDERED" > /dev/null 2>"$STUB_DIR/yq.err"; then
  echo "  OK: Rendered output is valid YAML"
else
  echo "  FAIL: Rendered output is not valid YAML:"
  cat "$STUB_DIR/yq.err" | sed 's/^/    /'
  echo ""
  echo "  First 20 lines of rendered output:"
  head -20 "$RENDERED" | sed 's/^/    /'
  exit 1
fi

KEYS=$(yq eval '. | keys | length' "$RENDERED" 2>/dev/null || echo "0")
echo "  OK: Rendered values.yaml has $KEYS top-level keys"
echo "  PASS: Validation complete"
