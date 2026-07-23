# KLASP Architecture

KLASP (Kubernetes Lifecycle Artifact Synthesis Pipeline) turns any Helm chart into
the four artifacts required to onboard an application into a GitOps lifecycle-
management system, with **no application-specific logic**. The only prerequisite is
a functional Helm chart.

## Pipeline

```
Input: Helm chart (repo URL + name + version) via a declarative manifest
  │
  ├─ fetch    → helm pull + extract values.yaml       → charts/<name>-<version>.tgz
  ├─ render   → helm template                          → output/<app>-rendered.yaml
  ├─ analyze  → knowledge-based classification          → output/<app>-fields.json
  ├─ emit     → value-driven matching                   → output artifacts
  └─ validate → gomplate render + CUE consistency check
```

### Core principle: no product/app-specific knowledge

The knowledge base (`knowledge-base/fields.yaml`) classifies fields **purely by
Kubernetes object structure** — never by application name or domain. Rendered
Kubernetes objects conform to well-known API schemas regardless of which chart
produced them, and that structural uniformity is sufficient to derive lifecycle
configuration. The framework contains no references to specific products.

Design bias: **superset over subset.** Over-extracting a static field (a human
removes it later) is preferable to missing a dynamic field (which fails in
production).

## Output artifacts

| File | Purpose | Datasource |
|------|---------|-----------|
| `golden-configuration/<app>/values.yaml.tmpl` | Gomplate template rendering Helm values | — |
| `presets/build/<release>.yaml` | Pinned image references + chart metadata | `$b` |
| `presets/resource/<release>/default.yaml` | CPU/memory requests+limits + replicas, tier-expandable | `$r` |
| `evars.yaml` | Orchestration config, endpoints, storage, sensitive placeholders | `$e` |

The **three-datasource separation** (`$b` build, `$r` resource, `$e` environment)
lets each concern change on its own cadence: a release updates only the build preset,
a scaling decision only the resource preset, and environment promotion only the
environment schema.

## Knowledge-based classification

For each rendered Kubernetes object, fields are classified and routed:

- **dynamic** → `{{ index $e "key" }}`, appears in `evars.yaml`
- **resource** → `{{ index $r "key" }}`, appears in `resource/default.yaml`
- **sensitive** → `{{ index $e "key_gen_sensitive" }}`, marked for encryption
- **static** → hardcoded in the template (not extracted)

Rules are organized by Kubernetes Kind (Deployment, StatefulSet, Service, Secret,
ConfigMap, Ingress, HorizontalPodAutoscaler, PersistentVolumeClaim, and RBAC kinds):

- **Deployment/StatefulSet**: image → `$b`; CPU/memory/replicas → `$r`; env vars by
  structural heuristic.
- **Service**: static unless `NodePort`/`LoadBalancer` (then type + nodePort → `$e`).
- **Secret**: all data values → sensitive (`$e`).
- **StatefulSet extras**: storageClassName and storage size → `$e`.
- **Ingress**: hosts and TLS → `$e`.
- **ConfigMap**: conservative heuristic (single-line URL/hostname values → `$e`).

Env-var heuristics are structural, not product-aware:

- value starts with `http://` / `https://` → dynamic (external endpoint);
- name ends with `HOST`/`ADDR`/`URL`/`ENDPOINT` → dynamic, unless the value matches
  `<word>:<port>` (intra-cluster);
- name matches `PASSWORD`/`SECRET`/`TOKEN`/`KEY` → sensitive.

Adding rules for a new Kind immediately benefits all charts, with no code changes.

## Value-driven golden-configuration synthesis

The emit stage produces templates by **value matching**, not path-pattern
assumptions:

1. Flatten the chart's `values.yaml` to all leaf `path → value` pairs.
2. For each classified field, search for its exact rendered value in that tree.
3. If found: replace in place with the gomplate expression, preserving YAML
   hierarchy.
4. If not found (value synthesized by a chart helper): fall back to a well-known
   path, or flag it to the user.
5. For combined image fields (registry embedded in the repository path): detect via
   substring match and emit a split expression.

This requires zero chart-specific path knowledge. Charts with embedded Helm template
syntax in `values.yaml` are cleaned at **emit time** — non-gomplate `{{ }}`
expressions are stripped during generation so templates are stored clean.

## Datasource routing (emit stage)

| Field type | Datasource | Output file |
|-----------|-----------|-------------|
| `image_registry`, `image_repository`, `image_tag` | `$b` | `presets/build/<release>.yaml` |
| `cpu`, `memory` | `$r` | `presets/resource/<release>/default.yaml` |
| `integer` ending in `_replicas` | `$r` | `presets/resource/<release>/default.yaml` |
| `storage_class`, `storage_size`, `string`, `env_var` | `$e` | `evars.yaml` |
| `sensitive_env` | `$e` | `evars.yaml` (encrypted) |

Multi-workload charts: when a chart renders more than one Deployment/StatefulSet,
each object's name discriminates keys, with the app-name prefix stripped to avoid
stutter (`hazelcast-mancenter` → `hazelcast_mancenter_*`, not
`hazelcast_hazelcast_mancenter_*`).

## Deployment model

Two orthogonal axes control deployment:

| Axis | Values | Determines |
|------|--------|------------|
| **mode** | `online` / `airgap` | Tool delivery: online fetches tools at runtime; airgap pulls from a seeded internal registry |
| **platform** | `local` / `gke` / `eks` / `openshift` | Auth mechanics, node scheduling, registry TLS |

These compose freely (e.g. `airgap` on a local cluster, `online` on a managed one).
A bootstrap step publishes presets + golden-config as ConfigMaps and creates deployer
CronJobs; the CronJobs then reconcile autonomously.

## Validation

- **CUE consistency**: every `$e`/`$r`/`$b` reference in a template resolves to a
  definition in the corresponding artifact; resource values are valid Kubernetes
  quantities.
- **Gomplate render**: stub data is generated from the classified fields and the
  template is rendered, verifying the output is well-formed YAML before any deploy.

## Language split (by design)

The classification engine — the intellectual core — is a typed, unit-tested Python
module (`src/analyzer.py`). The surrounding orchestration (fetch, emit, validate,
apply, deploy) is portable shell, because it contains gomplate `{{ }}` syntax that a
Go-templated task engine would misinterpret. CUE adds type-safe consistency
validation. Task orchestrates the whole flow identically on a laptop or in CI.
