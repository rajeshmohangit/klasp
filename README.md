# KLASP — Kubernetes Lifecycle Artifact Synthesis Pipeline

KLASP transforms **any Helm chart** into the four artifacts required to onboard an
application into a GitOps lifecycle-management system — without a single line of
application-specific logic. Its only prerequisite is a functional Helm chart.

By analyzing *rendered* Kubernetes objects (which conform to well-known API schemas
regardless of which chart produced them) against a declarative classification
knowledge base, KLASP derives lifecycle configuration structurally. The result is a
proof of *universal derivability*: lifecycle systems need not maintain per-application
adapters.

## What it generates

| Artifact | Purpose | Datasource |
|----------|---------|-----------|
| `golden-configuration/<app>/values.yaml.tmpl` | Gomplate template rendering Helm values | — |
| `presets/build/<release>.yaml` | Pinned image references + chart metadata | `$b` |
| `presets/resource/<release>/default.yaml` | CPU/memory/replicas, tier-expandable | `$r` |
| `evars.yaml` | Endpoints, storage, sensitive placeholders | `$e` |

## Pipeline

```
Helm chart manifest
  → fetch    (helm pull + extract values.yaml)
  → render   (helm template → K8s manifest stream)
  → analyze  (knowledge-based field classification, src/analyzer.py)
  → emit     (value-driven matching → artifacts)
  → validate (CUE consistency + gomplate render)
```

## Quick start

```bash
# Zero-config test suite (fetches example charts, generates + validates)
task test

# Generate from a manifest
task generate-multi MANIFEST=examples/multi-chart.yaml
```

## Requirements

Python 3.10+, PyYAML, Task v3.x, Helm v3.16+, yq v4+, jq 1.6+, cue v0.9+, gomplate v4+.

## Software quality

| Gate | Status |
|------|--------|
| Unit tests | 43 tests (`pytest tests/`) |
| Coverage | ~75% of the classification engine (branch coverage) |
| Python lint | `ruff check src/ tests/` — clean |
| Shell lint | `shellcheck --severity=warning scripts/*.sh` — clean (~2.1k LOC) |
| CI | `test.yaml` gates every push/PR: lint + unit tests + integration pipeline |
| Dependencies | Tool versions pinned via SBOM; Dependabot enabled |
| Deployer runtime | Minimal Chainguard images (zero-known-CVE objective) |

All gates run in GitHub Actions on every push and pull request.

## Continuous integration

Three GitHub Actions workflows (`.github/workflows/`):

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| **KLASP CI** (`test.yaml`) | every push / PR | Lint (shellcheck + ruff), unit tests with coverage, and the full generate-and-validate integration pipeline. This is the quality gate. |
| **KLASP: Generate Artifacts** (`generate.yaml`) | manual (`workflow_dispatch`) | Runs the pipeline on a chosen manifest, prints a per-chart field-count summary, and uploads the generated artifacts (`klasp-artifacts-<n>`) for download — no clone required to inspect output. |
| **KLASP: Build & Push Deployer Image** (`build-push.yaml`) | manual (`workflow_dispatch`) | Builds and pushes the deployer OCI image (online or air-gapped mode) to GHCR. |

External tool versions (yq, gomplate, cue) are pinned in each workflow to match
the SBOM manifest.

### Reproducing the generated artifacts

1. In the repository's **Actions** tab, open **KLASP: Generate Artifacts** and click
   **Run workflow**, choosing a manifest (default `examples/multi-chart.yaml`).
2. When the run finishes, its **Summary** page reports the per-chart field counts and
   the full output file tree.
3. Download the packaged output — named **`klasp-artifacts-<run-number>`** — either
   from the **Artifacts** section at the bottom of the run's Summary page, or via the
   GitHub CLI:

   ```bash
   gh run download <run-id> -n klasp-artifacts-<run-number>
   ```

   (GitHub sign-in is required to download Actions artifacts, even for public repos.)

The downloaded zip contains exactly the four onboarding artifacts plus the packaging
layer:

| Path in artifact | Purpose |
|------------------|---------|
| `golden-configuration/<app>/values.yaml.tmpl` | Gomplate templates rendering Helm values (`$b`/`$r`/`$e`) |
| `presets/build/<release>.yaml` | Pinned image references + chart metadata (`$b`) |
| `presets/resource/<release>/default.yaml` | CPU/memory/replicas per tier (`$r`) |
| `evars.yaml` | Environment schema: endpoints, storage, sensitive placeholders (`$e`) |
| `oci/` | Packaging layer: SBOM manifest, deployer Dockerfiles (online/air-gap), pull/build Taskfile |

## Repository layout

```
knowledge-base/fields.yaml   Declarative field classification (per K8s Kind)
src/analyzer.py              Knowledge-based classification engine (typed, tested)
tests/test_analyzer.py       Unit tests for the classification engine
scripts/                     Emit / validate / apply / deploy orchestration (shell)
base/                        Deployer CronJob templates (gomplate)
examples/                    Manifests for repeatable runs
environments/                Environment files (per deployment target)
docs/architecture.md         Design and pipeline internals
Taskfile.yaml                One-command orchestration
```

For the full design rationale — the knowledge-based classifier, value-driven
matching, three-datasource routing, and the two-axis deployment model — see
[`docs/architecture.md`](docs/architecture.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Citation

If you use KLASP in academic work, please cite the accompanying academic
publication. Citation details will be added here upon publication.
