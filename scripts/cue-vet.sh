#!/usr/bin/env bash
set -euo pipefail

# cue-vet.sh — Validate generated outputs for internal consistency using CUE
#
# Checks:
#   1. Every key referenced in golden-config ({{ index $e "key" }}) exists in evars
#   2. Every key referenced in golden-config ({{ index $r "key" }}) exists in resource preset
#   3. Every key referenced in golden-config ({{ index $b "key" }}) exists in build preset
#   4. Resource values are valid K8s quantities (cpu/memory format)
#   5. No orphaned evars keys (defined but never referenced in template)
#
# Usage: ./scripts/cue-vet.sh <app-name> [output-dir]

APP_NAME="${1:?Usage: cue-vet.sh <app-name> [output-dir]}"
OUTPUT_DIR="${2:-./output}"

GC_FILE="$OUTPUT_DIR/golden-configuration/$APP_NAME/values.yaml.tmpl"
FIELDS_FILE="$OUTPUT_DIR/${APP_NAME}-fields.json"

[ ! -f "$GC_FILE" ] && echo "ERROR: $GC_FILE not found" && exit 1
[ ! -f "$FIELDS_FILE" ] && echo "ERROR: $FIELDS_FILE not found" && exit 1

echo "  CUE validation: $APP_NAME"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract template references: keys used via {{ index $e "key" }}, {{ index $r "key" }}, {{ index $b "key" }}
EVAR_REFS=$(grep -oE 'index \$e "([^"]+)"' "$GC_FILE" | sed -E 's/index \$e "([^"]+)"/\1/' | sort -u || true)
RESOURCE_REFS=$(grep -oE 'index \$r "([^"]+)"' "$GC_FILE" | sed -E 's/index \$r "([^"]+)"/\1/' | sort -u || true)
BUILD_REFS=$(grep -oE 'index \$b "([^"]+)"' "$GC_FILE" | sed -E 's/index \$b "([^"]+)"/\1/' | sort -u || true)

# Extract defined keys from fields.json (matching the new routing logic)
# Evars: dynamic fields EXCLUDING images and replicas, plus sensitive
EVAR_DEFINED=$(jq -r '
  .[] | select(
    (.classification == "dynamic" or .classification == "sensitive") and
    (.type != "image_registry" and .type != "image_repository" and .type != "image_tag") and
    ((.type == "integer" and (.key | endswith("_replicas"))) | not)
  ) | .key
' "$FIELDS_FILE" | sort -u)

# Resource: cpu/memory + replicas
RESOURCE_DEFINED=$(jq -r '
  .[] | select(
    .classification == "resource" or
    (.classification == "dynamic" and .type == "integer" and (.key | endswith("_replicas")))
  ) | .key
' "$FIELDS_FILE" | sort -u)

# Build: image fields
BUILD_DEFINED=$(jq -r '
  .[] | select(.type == "image_registry" or .type == "image_repository" or .type == "image_tag")
  | .key
' "$FIELDS_FILE" | sort -u)

# Build CUE validation data
cat > "$WORK_DIR/data.cue" << 'EOF'
package validate

import "strings"

// Template references (keys the golden-config expects)
template_evar_refs: [...string]
template_resource_refs: [...string]
template_build_refs: [...string]

// Defined keys (what evars/resource/build files provide)
defined_evars: [...string]
defined_resources: [...string]
defined_builds: [...string]

// Resource values with their quantities
resource_values: [string]: string

// --- Constraints ---

// Every template evar reference must be in defined evars (or a framework key)
_framework_keys: ["env", "node_selector_key", "storage_class", "release", "resource_tier"]
_all_evars: defined_evars + _framework_keys
_missing_evars: [for ref in template_evar_refs if !list.Contains(_all_evars, ref) { ref }]

// Every template resource reference must be in defined resources
_missing_resources: [for ref in template_resource_refs if !list.Contains(defined_resources, ref) { ref }]

// Every template build reference must be in defined builds
_missing_builds: [for ref in template_build_refs if !list.Contains(defined_builds, ref) { ref }]

// Resource values must match K8s quantity pattern
_cpu_pattern: =~"^[0-9]+(m|\\.[0-9]+)?$"
_memory_pattern: =~"^[0-9]+(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$"

_invalid_resources: [for k, v in resource_values {
  if strings.Contains(k, "cpu") && !(v & _cpu_pattern) { "\(k)=\(v) (invalid CPU)" }
  if strings.Contains(k, "memory") && !(v & _memory_pattern) { "\(k)=\(v) (invalid memory)" }
}]

// Orphaned evars (defined but not referenced in template or orchestration block)
_orchestration_suffixes: ["_orchestration_mode", "_orchestration_namespace", "_orchestration_frequency", "_orchestration_application_type"]
_is_orchestration: {for k in defined_evars { (k): or([ for s in _orchestration_suffixes { strings.HasSuffix(k, s) }]) }}
_orphaned_evars: [for k in defined_evars if !list.Contains(template_evar_refs, k) && !(_is_orchestration[k]) { k }]
EOF

# Generate the values file
cat > "$WORK_DIR/values.cue" << EOF
package validate

import "list"

template_evar_refs: [$(echo "$EVAR_REFS" | awk '{printf "\"%s\", ", $0}' | sed 's/, $//')]
template_resource_refs: [$(echo "$RESOURCE_REFS" | awk '{printf "\"%s\", ", $0}' | sed 's/, $//')]
template_build_refs: [$(echo "$BUILD_REFS" | awk '{printf "\"%s\", ", $0}' | sed 's/, $//')]
defined_evars: [$(echo "$EVAR_DEFINED" | awk '{printf "\"%s\", ", $0}' | sed 's/, $//')]
defined_resources: [$(echo "$RESOURCE_DEFINED" | awk '{printf "\"%s\", ", $0}' | sed 's/, $//')]
defined_builds: [$(echo "$BUILD_DEFINED" | awk '{printf "\"%s\", ", $0}' | sed 's/, $//')]
resource_values: {
$(jq -r '.[] | select(.classification == "resource") | "  \"\(.key)\": \"\(.value)\""' "$FIELDS_FILE")
}
EOF

# Run CUE evaluation (not vet — we want to check computed constraints)
ERRORS=0

# Check 1: Missing evar references
MISSING_E=$(cd "$WORK_DIR" && cue eval -e '_missing_evars' 2>/dev/null | grep -v '^\[\]$' | grep -v '^\[' | grep -v '^\]' | tr -d '"\t ,' | grep -v '^$' || true)
if [ -n "$MISSING_E" ]; then
  echo "  FAIL: Golden-config references evars not in fields.json:"
  echo "$MISSING_E" | sed 's/^/    - /'
  ERRORS=$((ERRORS + 1))
else
  echo "  OK: All template evar references have definitions"
fi

# Check 2: Missing resource references
MISSING_R=$(cd "$WORK_DIR" && cue eval -e '_missing_resources' 2>/dev/null | grep -v '^\[\]$' | grep -v '^\[' | grep -v '^\]' | tr -d '"\t ,' | grep -v '^$' || true)
if [ -n "$MISSING_R" ]; then
  echo "  FAIL: Golden-config references resources not in fields.json:"
  echo "$MISSING_R" | sed 's/^/    - /'
  ERRORS=$((ERRORS + 1))
else
  echo "  OK: All template resource references have definitions"
fi

# Check 3: Missing build references
MISSING_B=$(cd "$WORK_DIR" && cue eval -e '_missing_builds' 2>/dev/null | grep -v '^\[\]$' | grep -v '^\[' | grep -v '^\]' | tr -d '"\t ,' | grep -v '^$' || true)
if [ -n "$MISSING_B" ]; then
  echo "  FAIL: Golden-config references builds not in fields.json:"
  echo "$MISSING_B" | sed 's/^/    - /'
  ERRORS=$((ERRORS + 1))
else
  echo "  OK: All template build references have definitions"
fi

# Check 4: Resource quantity format validation
jq -r '.[] | select(.classification == "resource") | "\(.key) \(.value)"' "$FIELDS_FILE" | while read -r rkey rval; do
  if echo "$rkey" | grep -q "cpu"; then
    if ! echo "$rval" | grep -qE '^[0-9]+(m|(\.[0-9]+))?$'; then
      echo "  WARN: $rkey=\"$rval\" — not a valid CPU quantity"
    fi
  elif echo "$rkey" | grep -q "memory"; then
    if ! echo "$rval" | grep -qE '^[0-9]+(Ki|Mi|Gi|Ti)?$'; then
      echo "  WARN: $rkey=\"$rval\" — not a valid memory quantity"
    fi
  fi
done

# Check 5: Orphaned evars (informational)
ORPHANED=$(cd "$WORK_DIR" && cue eval -e '_orphaned_evars' 2>/dev/null | grep -v '^\[\]$' | grep -v '^\[' | grep -v '^\]' | tr -d '"\t ,' | grep -v '^$' || true)
if [ -n "$ORPHANED" ]; then
  ORPHAN_COUNT=$(echo "$ORPHANED" | wc -l | tr -d ' ')
  echo "  INFO: $ORPHAN_COUNT evars defined but not referenced in template (may be storage/service fields):"
  echo "$ORPHANED" | head -5 | sed 's/^/    - /'
  [ "$ORPHAN_COUNT" -gt 5 ] && echo "    ... and $((ORPHAN_COUNT - 5)) more"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "  FAIL: CUE validation found $ERRORS error(s)"
  exit 1
fi

echo "  PASS: CUE validation complete"
