#!/usr/bin/env bash
set -euo pipefail

# emit.sh — Transform fields.json into golden-config, build preset, resource preset, and evars
#
# Golden-config strategy:
#   1. Flatten the chart's values.yaml to all leaf path→value pairs
#   2. For each field in fields.json, find its rendered value in the flattened values.yaml
#   3. If found: replace that value with the gomplate expression
#   4. If NOT found: flag it to the user (value was synthesized by a preset/helper)
#
# Output routing:
#   - Image fields (registry/repo/tag) → build preset ($b datasource)
#   - Resource fields (cpu/mem) + replicas → resource preset ($r datasource)
#   - Everything else (orchestration, endpoints, storage, sensitive) → evars ($e datasource)
#
# Usage: ./scripts/emit.sh <app-name> <chart-repo> <chart-name> <chart-version> [output-dir] [charts-dir] [release-name]

APP_NAME="${1:?Usage: emit.sh <app-name> <chart-repo> <chart-name> <chart-version> [output-dir] [charts-dir] [release-name]}"
CHART_REPO="${2:?}"
CHART_NAME="${3:?}"
CHART_VERSION="${4:?}"
OUTPUT_DIR="${5:-./output}"
CHARTS_DIR="${6:-./charts}"
RELEASE="${7:-$APP_NAME}"

APP_KEY=$(echo "$APP_NAME" | tr '-' '_')
FIELDS_FILE="$OUTPUT_DIR/${APP_NAME}-fields.json"
VALUES_FILE="${CHARTS_DIR}/${CHART_NAME}-${CHART_VERSION}-values.yaml"

if [ ! -f "$FIELDS_FILE" ]; then
  echo "ERROR: $FIELDS_FILE not found — run analyze first"
  exit 1
fi

if [ ! -f "$VALUES_FILE" ]; then
  echo "ERROR: $VALUES_FILE not found — chart values.yaml not extracted during fetch"
  exit 1
fi

# --- Create output directories ---
# Structure: presets/build/<release>.yaml
#            presets/resource/<release>/default.yaml
GC_DIR="$OUTPUT_DIR/golden-configuration/$APP_NAME"
PRESET_BUILD_DIR="$OUTPUT_DIR/presets/build"
PRESET_RESOURCE_DIR="$OUTPUT_DIR/presets/resource/$RELEASE"
mkdir -p "$GC_DIR" "$PRESET_BUILD_DIR" "$PRESET_RESOURCE_DIR"

echo "=== Generating outputs for: $APP_NAME (release: $RELEASE) ==="

# ============================================================================
# 1. GOLDEN CONFIGURATION (values.yaml.tmpl)
# ============================================================================
GC_FILE="$GC_DIR/values.yaml.tmpl"

# Flatten values.yaml: tab-separated "path\tvalue" for every leaf
FLAT_FILE=$(mktemp)
trap 'rm -f "$FLAT_FILE"' EXIT
yq eval '.. | select(tag != "!!map" and tag != "!!seq") | [path | join("."), .] | @tsv' "$VALUES_FILE" > "$FLAT_FILE" 2>/dev/null || true

# For each field in fields.json, find where its value exists in the flat values.yaml
# Output: substitution file (yaml_path \t gomplate_expression) and unmatched report
SUBS_FILE="$OUTPUT_DIR/${APP_NAME}-substitutions.tsv"
UNMATCHED_FILE="$OUTPUT_DIR/${APP_NAME}-unmatched.txt"
: > "$SUBS_FILE"
: > "$UNMATCHED_FILE"

echo "  Matching fields to values.yaml paths..."

FIELD_COUNT=$(jq length "$FIELDS_FILE")
MATCHED=0
FLAGGED=0

# Helper: determine which datasource a field belongs to
field_datasource() {
  local _cls="$1" _ftype="$2" _key="$3"
  if [ "$_cls" = "resource" ]; then
    echo "r"
  elif [ "$_cls" = "sensitive" ]; then
    echo "e"
  elif echo "$_ftype" | grep -qE "^(image_registry|image_repository|image_tag)$"; then
    echo "b"
  elif [ "$_ftype" = "integer" ] && echo "$_key" | grep -qE "_replicas$"; then
    echo "r"
  else
    echo "e"
  fi
}

for fidx in $(seq 0 $((FIELD_COUNT - 1))); do
  cls=$(jq -r ".[$fidx].classification" "$FIELDS_FILE")
  key=$(jq -r ".[$fidx].key" "$FIELDS_FILE")
  value=$(jq -r ".[$fidx].value" "$FIELDS_FILE")
  ftype=$(jq -r ".[$fidx].type" "$FIELDS_FILE")
  source_name=$(jq -r ".[$fidx].source_name" "$FIELDS_FILE")

  # Skip fields with empty values (e.g., sensitive placeholders)
  [ -z "$value" ] && continue

  # Determine which datasource this field routes to
  ds=$(field_datasource "$cls" "$ftype" "$key")

  # Build the gomplate expression based on datasource
  case "$ds" in
    b)  expr='{{ index $b "'"$key"'" | default "'"$value"'" }}' ;;
    r)  expr='{{ index $r "'"$key"'" | default "'"$value"'" }}' ;;
    e)
      if [ "$ftype" = "storage_class" ]; then
        expr='{{ index $e "'"$key"'" | default (index $e "storage_class") }}'
      elif [ "$cls" = "sensitive" ]; then
        expr='{{ index $e "'"$key"'" }}'
      else
        expr='{{ index $e "'"$key"'" | default "'"$value"'" }}'
      fi
      ;;
  esac

  # For image fields, the rendered value may be a component (registry, repo, tag)
  # split from a combined value in values.yaml (e.g., "ghcr.io/org/app" contains both).
  # Handle image_registry specially: it might be embedded in a "repository" path.
  # We search for the exact value as a leaf in values.yaml.

  # Find all matching paths (value must be an EXACT leaf value, not substring)
  # Tab-separated format: path\tvalue — match the value column exactly
  matched_paths=$(awk -F'\t' -v val="$value" '$2 == val {print $1}' "$FLAT_FILE")

  if [ -n "$matched_paths" ]; then
    # --- EXACT MATCH FOUND ---
    # Pick the best path if multiple match
    best_path=""
    if [ "$(echo "$matched_paths" | wc -l)" -eq 1 ]; then
      best_path="$matched_paths"
    else
      # Disambiguate using source_name
      source_lower=$(echo "$source_name" | tr '[:upper:]' '[:lower:]' | tr -d '-')
      filtered=$(echo "$matched_paths" | grep -i "$source_lower" || true)
      if [ -n "$filtered" ]; then
        best_path=$(echo "$filtered" | head -1)
      else
        # Prefer paths with relevant keywords for the field type
        if echo "$ftype" | grep -q "image"; then
          filtered=$(echo "$matched_paths" | grep -i "image" || true)
          [ -n "$filtered" ] && best_path=$(echo "$filtered" | head -1)
        fi
        if [ -z "$best_path" ] && ([ "$ftype" = "cpu" ] || [ "$ftype" = "memory" ]); then
          filtered=$(echo "$matched_paths" | grep -i "resources" || true)
          [ -n "$filtered" ] && best_path=$(echo "$filtered" | head -1)
        fi
        [ -z "$best_path" ] && best_path=$(echo "$matched_paths" | awk '{print length, $0}' | sort -n | head -1 | cut -d' ' -f2-)
      fi
    fi

    printf '%s\t%s\n' "$best_path" "$expr" >> "$SUBS_FILE"
    MATCHED=$((MATCHED + 1))
    continue
  fi

  # --- NO EXACT MATCH — check for substring/embedded cases ---
  substr_paths=$(awk -F'\t' -v val="$value" 'index($2, val) > 0 {print $1}' "$FLAT_FILE")

  if [ -z "$substr_paths" ]; then
    # Resource fields synthesized by chart helpers (e.g., Bitnami resourcesPreset)
    # fall back to injecting at the well-known resources path in values.yaml
    if [ "$cls" = "resource" ] && ([ "$ftype" = "cpu" ] || [ "$ftype" = "memory" ]); then
      res_yaml_path=""
      # Derive requests vs limits and leaf type from the key name
      if echo "$key" | grep -q "requests_"; then
        res_tier="requests"
      elif echo "$key" | grep -q "limits_"; then
        res_tier="limits"
      fi
      if [ -n "$res_tier" ]; then
        # Find which parent object has a "resources" key (may be empty map)
        # Use yq to find all paths that contain a "resources" key
        res_parents=$(yq eval '[.. | select(has("resources")) | path | join(".")] | .[]' "$VALUES_FILE" 2>/dev/null || true)
        if [ -n "$res_parents" ]; then
          # Multi-parent: disambiguate by source_name
          if [ "$(echo "$res_parents" | wc -l | tr -d ' ')" -gt 1 ]; then
            source_lower=$(echo "$source_name" | tr '[:upper:]' '[:lower:]' | tr -d '-')
            filtered=$(echo "$res_parents" | grep -i "$source_lower" || true)
            [ -n "$filtered" ] && res_parents=$(echo "$filtered" | head -1)
          fi
          parent_path=$(echo "$res_parents" | head -1)
          if [ -n "$parent_path" ]; then
            res_yaml_path="${parent_path}.resources.${res_tier}.${ftype}"
          else
            res_yaml_path="resources.${res_tier}.${ftype}"
          fi
        else
          # Top-level resources key
          res_yaml_path="resources.${res_tier}.${ftype}"
        fi
      fi
      if [ -n "$res_yaml_path" ]; then
        printf '%s\t%s\n' "$res_yaml_path" "$expr" >> "$SUBS_FILE"
        MATCHED=$((MATCHED + 1))
        continue
      fi
    fi
    # Truly not found anywhere
    FLAGGED=$((FLAGGED + 1))
    printf '%-50s %-12s %s\n' "$key" "[$cls]" "value=\"$value\" (not in values.yaml — synthesized by preset/helper)" >> "$UNMATCHED_FILE"
    continue
  fi

  # Combined image case: registry is embedded in a "registry/repository" combined field
  # Only match when: 1) the path name relates to this workload, and 2) value starts with registry/
  if [ "$ftype" = "image_registry" ]; then
    source_lower=$(echo "$source_name" | tr '[:upper:]' '[:lower:]' | tr -d '-')
    # Filter to paths that contain the source workload name
    filtered=$(echo "$substr_paths" | grep -i "$source_lower" || true)
    if [ -n "$filtered" ]; then
      # Verify the combined value at path actually starts with our registry
      repo_path=$(echo "$filtered" | head -1)
      path_value=$(awk -F'\t' -v p="$repo_path" '$1 == p {print $2}' "$FLAT_FILE")
      if echo "$path_value" | grep -q "^${value}/"; then
        printf '%s\tCOMBINED_IMAGE\t%s\n' "$repo_path" "$key" >> "$SUBS_FILE"
        MATCHED=$((MATCHED + 1))
        continue
      fi
    fi
    # No valid combined match — flag as unmatched
    FLAGGED=$((FLAGGED + 1))
    printf '%-50s %-12s %s\n' "$key" "[$cls]" "value=\"$value\" (not in values.yaml — synthesized by preset/helper)" >> "$UNMATCHED_FILE"
    continue
  fi

  # Combined image case: repository is the suffix after "registry/" in the combined field
  if [ "$ftype" = "image_repository" ]; then
    source_lower=$(echo "$source_name" | tr '[:upper:]' '[:lower:]' | tr -d '-')
    filtered=$(echo "$substr_paths" | grep -i "$source_lower" || true)
    if [ -n "$filtered" ]; then
      repo_path=$(echo "$filtered" | head -1)
    else
      repo_path=$(echo "$substr_paths" | head -1)
    fi
    if grep -q "^${repo_path}	COMBINED_IMAGE" "$SUBS_FILE" 2>/dev/null; then
      reg_key=$(grep "^${repo_path}	COMBINED_IMAGE" "$SUBS_FILE" | cut -f3)
      grep -v "^${repo_path}	COMBINED_IMAGE" "$SUBS_FILE" > "${SUBS_FILE}.tmp" && mv "${SUBS_FILE}.tmp" "$SUBS_FILE"
      combined_expr='{{ index $b "'"$reg_key"'" }}/{{ index $b "'"$key"'" }}'
      printf '%s\t%s\n' "$repo_path" "$combined_expr" >> "$SUBS_FILE"
      MATCHED=$((MATCHED + 1))
      continue
    fi
  fi

  # Otherwise: flag as embedded
  FLAGGED=$((FLAGGED + 1))
  printf '%-50s %-12s %s\n' "$key" "[$cls]" "value=\"$value\" (embedded in $(echo "$substr_paths" | head -1) — needs manual mapping)" >> "$UNMATCHED_FILE"
done

# Handle any remaining COMBINED_IMAGE markers (registry found but repo wasn't processed after)
if grep -q "COMBINED_IMAGE" "$SUBS_FILE" 2>/dev/null; then
  grep -v "COMBINED_IMAGE" "$SUBS_FILE" > "${SUBS_FILE}.tmp" && mv "${SUBS_FILE}.tmp" "$SUBS_FILE"
fi

echo "  Matched: $MATCHED fields → values.yaml paths"
if [ "$FLAGGED" -gt 0 ]; then
  echo "  Flagged: $FLAGGED fields not found in values.yaml (see ${UNMATCHED_FILE})"
  echo ""
  echo "  ⚠ Unmatched fields (synthesized by chart presets/helpers):"
  cat "$UNMATCHED_FILE" | sed 's/^/    /'
  echo ""
fi

# Build the golden-config template
SUBS_COUNT=$(wc -l < "$SUBS_FILE" | tr -d ' ')

cat > "$GC_FILE" << 'PREAMBLE'
{{- $e := datasource "env" -}}
{{- $r := datasource "resource" -}}
{{- $b := datasource "build" -}}
{{- $app_key := getenv "APP_NAME" | strings.ReplaceAll "-" "_" -}}
{{- $nsk := index $e "node_selector_key" | default "environment" -}}
{{- if (coll.Has $e (printf "%s_node_selector_key" $app_key)) }}{{ $nsk = index $e (printf "%s_node_selector_key" $app_key) }}{{ end -}}

PREAMBLE

if [ "$SUBS_COUNT" -gt 0 ]; then
  # Apply substitutions via yq (set placeholders) then perl (replace with expressions)
  WORK_FILE=$(mktemp)
  MAP_FILE=$(mktemp)
  cp "$VALUES_FILE" "$WORK_FILE"

  while IFS=$'\t' read -r yaml_path expr; do
    [ -z "$yaml_path" ] && continue
    placeholder="GOMPLATE_$(echo "$yaml_path" | md5sum | cut -c1-12)"
    yq eval ".${yaml_path} = \"${placeholder}\"" -i "$WORK_FILE" 2>/dev/null || true
    printf '%s\t%s\n' "$placeholder" "$expr" >> "$MAP_FILE"
  done < "$SUBS_FILE"

  # Replace placeholders with gomplate expressions using perl (handles special chars)
  FINAL_FILE=$(mktemp)
  cp "$WORK_FILE" "$FINAL_FILE"

  while IFS=$'\t' read -r placeholder expr; do
    [ -z "$placeholder" ] && continue
    perl -pi -e "BEGIN{\$p=q(${placeholder}); \$e=q(${expr})} s/\"\Q\$p\E\"/\$e/g; s/'\Q\$p\E'/\$e/g; s/\Q\$p\E/\$e/g" "$FINAL_FILE"
  done < "$MAP_FILE"

  cat "$FINAL_FILE" >> "$GC_FILE"
  rm -f "$WORK_FILE" "$MAP_FILE" "$FINAL_FILE"
else
  echo "# WARNING: No fields matched for templatization" >> "$GC_FILE"
  cat "$VALUES_FILE" >> "$GC_FILE"
fi

# Append nodeSelector framework pattern
cat >> "$GC_FILE" << 'NODESELECTOR'

# --- Scheduling (framework pattern) ---
nodeSelector:
  {{ $nsk }}: {{ index $e "env" }}
NODESELECTOR

# Strip non-gomplate template expressions (Helm {{ .Values }}, {{ template }}, etc.)
# Our gomplate expressions always reference $e, $r, $b, $app_key, $nsk, datasource, or getenv.
# Everything else is chart-embedded Helm syntax that must be removed for gomplate to parse.
# Also strip orphan {{ or }} on lines that don't contain our gomplate keywords.
perl -pi -e '
  if (/\{\{/ && !/\$e\b|\$r\b|\$b\b|\$app_key|\$nsk|datasource\s+"|getenv/) {
    s/\{\{-?\s*.*?\s*-?\}\}//g;
    s/\{\{//g;
    s/\}\}//g;
    if (/^\s*$/) { $_ = "\n"; }
  }
' "$GC_FILE"

echo "  Generated: $GC_FILE"

# ============================================================================
# 2. EVARS (lean env-schema — no image fields, no replicas, no resources)
# ============================================================================
EVARS_FILE="$OUTPUT_DIR/evars.yaml"

cat > "$EVARS_FILE" << EOF
# Environment variables schema for: $APP_NAME
# Generated from chart: $CHART_NAME ($CHART_VERSION)
# Classification: environment-varying fields only (no images, resources, or replicas)
#
# Usage: Merge into your environments/<env>.yaml (SOPS encrypted)

# --- Framework (selects which preset files the deployer loads) ---
release: ${RELEASE}
resource_tier: default

# --- Orchestration ---
${APP_KEY}_orchestration_mode: reconcile
${APP_KEY}_orchestration_namespace: ${APP_NAME}-\${env}
${APP_KEY}_orchestration_frequency: "*/2 * * * *"
${APP_KEY}_orchestration_application_type: helm

EOF

# Add global dependency note if storage_class fields exist
HAS_SC=$(jq '[.[] | select(.type == "storage_class")] | length' "$FIELDS_FILE")
if [ "$HAS_SC" -gt 0 ]; then
  cat >> "$EVARS_FILE" << 'EOF'
# --- Global dependencies (must exist in environment) ---
# storage_class: <platform default, e.g. gp3 (EKS), standard-rwo (GKE/OCP)>

EOF
fi

echo "# --- Dynamic fields ---" >> "$EVARS_FILE"
# Only emit dynamic fields that are NOT image fields and NOT replicas
jq -r '
  .[] | select(.classification == "dynamic")
  | select(.type != "image_registry" and .type != "image_repository" and .type != "image_tag")
  | select((.type == "integer" and (.key | endswith("_replicas"))) | not)
  | "\(.key): \(.value)"
' "$FIELDS_FILE" >> "$EVARS_FILE"
echo "" >> "$EVARS_FILE"

echo "# --- Sensitive fields (auto-generated, SOPS encrypted) ---" >> "$EVARS_FILE"
jq -r '.[] | select(.classification == "sensitive") | "\(.key): \"\"  # auto-generated"' "$FIELDS_FILE" >> "$EVARS_FILE"

echo "  Generated: $EVARS_FILE"

# ============================================================================
# 3. BUILD PRESET (presets/build/<release>.yaml)
# ============================================================================
BUILD_FILE="$PRESET_BUILD_DIR/${RELEASE}.yaml"

cat > "$BUILD_FILE" << EOF
# Build preset: $RELEASE
# Generated from chart: $CHART_NAME ($CHART_VERSION)
# Image versions and chart metadata pinned at build time

# --- Chart metadata ---
${APP_KEY}_helm_chart: ${CHART_NAME}
${APP_KEY}_helm_chart_version: "${CHART_VERSION}"
${APP_KEY}_helm_chart_repo: $(if [ -d "$CHART_REPO" ]; then echo "local"; else echo "$CHART_REPO"; fi)

# --- Images ---
EOF

jq -r '
  .[] | select(.type == "image_registry" or .type == "image_repository" or .type == "image_tag")
  | "\(.key): \"\(.value)\""
' "$FIELDS_FILE" >> "$BUILD_FILE"

# Add digest placeholders for each image
jq -r '.[] | select(.type == "image_tag") | .key' "$FIELDS_FILE" | sed -E 's/_tag$/_digest/' | while read -r digest_key; do
  echo "${digest_key}: \"\"" >> "$BUILD_FILE"
done

echo "  Generated: $BUILD_FILE"

# ============================================================================
# 4. RESOURCE PRESET (cpu/memory + replicas)
# ============================================================================
RESOURCE_FILE="$PRESET_RESOURCE_DIR/default.yaml"

cat > "$RESOURCE_FILE" << EOF
# Resource preset: default
# Generated from chart: $CHART_NAME ($CHART_VERSION)
# Adjust per scaling tier (e.g., 1k, 10k, 200k)

EOF

# Replicas (from dynamic fields with type=integer and key ending in _replicas)
jq -r '
  .[] | select(.classification == "dynamic")
  | select(.type == "integer" and (.key | endswith("_replicas")))
  | "\(.key): \"\(.value)\""
' "$FIELDS_FILE" | sort >> "$RESOURCE_FILE"

# CPU/memory (from resource classification)
jq -r '.[] | select(.classification == "resource") | "\(.key): \"\(.value)\""' "$FIELDS_FILE" | sort >> "$RESOURCE_FILE"

echo "  Generated: $RESOURCE_FILE"

echo ""
echo "=== Generation complete ==="
echo "  Output directory: $OUTPUT_DIR/"
echo "  Files:"
echo "    - golden-configuration/$APP_NAME/values.yaml.tmpl"
echo "    - evars.yaml"
echo "    - presets/build/${RELEASE}.yaml"
echo "    - presets/resource/$RELEASE/default.yaml"
[ "$FLAGGED" -gt 0 ] && echo "    - ${APP_NAME}-unmatched.txt (review flagged fields)"
exit 0
