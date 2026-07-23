#!/usr/bin/env python3
"""
Kubernetes manifest analyzer for KLASP.

Parses rendered multi-document K8s YAML, classifies fields based on
the knowledge base (knowledge-base/fields.yaml), and outputs a
deduplicated JSON array of field entries.

Usage:
    python3 src/analyzer.py <app-name> [--output-dir ./output] [--kb knowledge-base/fields.yaml]
"""

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import yaml

# --- Data Model ---

@dataclass
class Field:
    classification: str
    key: str
    value: str
    type: str
    source_kind: str
    source_name: str


# --- Utility Functions ---

def workload_suffix(obj_name: str, app_name: str) -> str:
    """
    Derive a clean workload suffix by stripping the app name prefix.

    "hazelcast" (same as app) -> "" (main workload, no suffix needed)
    "hazelcast-mancenter" -> "mancenter"
    "other-name" (unrelated) -> "other_name" (keep as-is)
    """
    if obj_name == app_name:
        return ""
    elif obj_name.startswith(f"{app_name}-"):
        return obj_name[len(app_name) + 1:].replace("-", "_")
    else:
        return obj_name.replace("-", "_")


def split_image(image: str) -> tuple[str, str, str]:
    """
    Split a container image reference into (registry, repository, tag).

    Handles:
    - @sha256:... digest references
    - :tag suffixes
    - Registry detection (first path component has '.' or ':')
    - Default tag "latest" when none specified
    """
    digest = ""
    ref = image

    # Handle @digest
    if "@" in ref:
        digest = ref[ref.index("@") + 1:]
        ref = ref[:ref.index("@")]

    # Handle :tag
    tag = ""
    repo = ""
    if re.search(r":[^/]+$", ref):
        tag = ref[ref.rfind(":") + 1:]
        repo = ref[:ref.rfind(":")]
    elif digest:
        tag = digest
        repo = ref
    else:
        tag = "latest"
        repo = ref

    # Detect registry (first path component has '.' or ':')
    registry = ""
    repository = repo
    if "/" in repo:
        first = repo.split("/")[0]
        if "." in first or ":" in first:
            registry = first
            repository = repo[len(first) + 1:]

    return registry, repository, tag


def is_sensitive_env_name(name: str) -> bool:
    """Check if an env var name matches the sensitive pattern."""
    pattern = r"PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|COOKIE|PRIVATE_KEY|API_KEY"
    return bool(re.search(pattern, name, re.IGNORECASE))


def is_dynamic_env(name: str, value: str) -> bool:
    """
    Determine if an env var should be classified as dynamic.

    - Value starts with http:// or https:// -> dynamic (external endpoint)
    - Name ends with HOST/HOSTNAME/DOMAIN/URL/ENDPOINT/ADDR/ADDRESS/URI -> dynamic
      UNLESS value matches intra-cluster pattern (word:port)
    """
    # URL value
    if re.match(r"^https?://", value):
        return True

    # Host/endpoint name pattern
    endpoint_suffix = r"HOST$|HOSTNAME$|DOMAIN$|URL$|ENDPOINT$|ADDR$|ADDRESS$|URI$"
    if re.search(endpoint_suffix, name, re.IGNORECASE):
        # Skip intra-cluster references (e.g., "redis:6379")
        if re.match(r"^[a-zA-Z0-9_-]+:[0-9]+$", value):
            return False
        return True

    return False


def is_multiline(value: str) -> bool:
    """Check if a value has more than 3 lines (used for ConfigMap heuristic)."""
    return value.count("\n") > 3


def is_url_or_fqdn(value: str) -> bool:
    """Check if a value matches URL or FQDN pattern."""
    return bool(re.match(r"^https?://|^[a-z0-9.-]+\.[a-z]{2,}(:[0-9]+)?$", value))


def normalize_key(name: str) -> str:
    """Normalize a key name: lowercase, replace '.' and '-' with '_'."""
    return name.lower().replace(".", "_").replace("-", "_")


# --- Analyzer ---

class Analyzer:
    """Analyzes rendered K8s manifests and classifies fields."""

    def __init__(self, app_name: str, output_dir: Path, kb_path: Path | None = None):
        self.app_name = app_name
        self.app_key = app_name.replace("-", "_")
        self.output_dir = output_dir
        self.fields: list[Field] = []

        # Load knowledge base (for future extensibility; current logic is inline)
        if kb_path and kb_path.exists():
            with open(kb_path) as f:
                self.kb = yaml.safe_load(f)
        else:
            self.kb = {}

    def add_field(self, classification: str, key: str, value: str,
                  field_type: str, source_kind: str, source_name: str) -> None:
        """Add a field entry to the results."""
        self.fields.append(Field(
            classification=classification,
            key=key,
            value=value,
            type=field_type,
            source_kind=source_kind,
            source_name=source_name,
        ))

    def analyze(self) -> list[dict]:
        """Run the full analysis pipeline."""
        rendered_path = self.output_dir / f"{self.app_name}-rendered.yaml"
        if not rendered_path.exists():
            print(f"ERROR: {rendered_path} not found", file=sys.stderr)
            sys.exit(1)

        # Parse multi-document YAML
        with open(rendered_path) as f:
            docs = list(yaml.safe_load_all(f))

        # Filter out null/empty documents
        docs = [d for d in docs if d and isinstance(d, dict) and d.get("kind")]

        print(f"  Analyzing {len(docs)} objects for app: {self.app_name} (key: {self.app_key})")

        # Count workloads for multi-workload logic
        workload_kinds = {"Deployment", "StatefulSet"}
        workload_count = sum(1 for d in docs if d.get("kind") in workload_kinds)
        multi_workload = workload_count > 1

        # Process each document
        for idx, doc in enumerate(docs):
            kind = doc.get("kind", "")
            obj_name = doc.get("metadata", {}).get("name", "")
            if not kind:
                continue

            print(f"    [{idx}] {kind}/{obj_name}")

            if kind in ("Deployment", "StatefulSet"):
                self._analyze_workload(doc, kind, obj_name, multi_workload)
            elif kind == "Service":
                self._analyze_service(doc, kind, obj_name)
            elif kind == "Secret":
                self._analyze_secret(doc, kind, obj_name)
            elif kind == "ConfigMap":
                self._analyze_configmap(doc, kind, obj_name)
            elif kind == "Ingress":
                self._analyze_ingress(doc, kind, obj_name)
            elif kind == "HorizontalPodAutoscaler":
                self._analyze_hpa(doc, kind, obj_name)
            elif kind == "PersistentVolumeClaim":
                self._analyze_pvc(doc, kind, obj_name)
            else:
                print(f"      (skipped: {kind} not in knowledge base)")

        # Deduplicate by key (keep first occurrence) and sort by key
        return self._deduplicate()

    def _deduplicate(self) -> list[dict]:
        """Deduplicate fields by key, keeping first occurrence, then sort by key."""
        seen: dict[str, Field] = {}
        for field in self.fields:
            if field.key not in seen:
                seen[field.key] = field
        # Sort by key (matches jq unique_by behavior)
        sorted_fields = sorted(seen.values(), key=lambda f: f.key)
        return [asdict(f) for f in sorted_fields]

    def _analyze_workload(self, doc: dict, kind: str, obj_name: str,
                          multi_workload: bool) -> None:
        """Analyze Deployment or StatefulSet."""
        spec = doc.get("spec", {})

        # Replicas
        replicas = spec.get("replicas", 1)
        if replicas is None:
            replicas = 1
        replicas_str = str(replicas)

        if multi_workload:
            w_suffix = workload_suffix(obj_name, self.app_name)
            if w_suffix:
                replicas_key = f"{self.app_key}_{w_suffix}_replicas"
            else:
                replicas_key = f"{self.app_key}_replicas"
        else:
            replicas_key = f"{self.app_key}_replicas"

        self.add_field("dynamic", replicas_key, replicas_str, "integer", kind, obj_name)

        # Containers
        template_spec = spec.get("template", {}).get("spec", {})
        containers = template_spec.get("containers", [])
        container_count = len(containers)

        for container in containers:
            cname = container.get("name", "")
            image = container.get("image", "")
            if not image:
                continue

            # Determine image key prefix
            img_prefix = self._image_prefix(
                obj_name, cname, multi_workload, container_count
            )

            # Split and add image fields
            registry, repository, tag = split_image(image)
            self.add_field("dynamic", f"{img_prefix}_image_registry", registry,
                           "image_registry", kind, obj_name)
            self.add_field("dynamic", f"{img_prefix}_image_repository", repository,
                           "image_repository", kind, obj_name)
            self.add_field("dynamic", f"{img_prefix}_image_tag", tag,
                           "image_tag", kind, obj_name)

            # Resource requests/limits
            resources = container.get("resources", {})
            requests = resources.get("requests", {}) if resources else {}
            limits = resources.get("limits", {}) if resources else {}

            if requests:
                req_cpu = requests.get("cpu")
                req_mem = requests.get("memory")
                if req_cpu:
                    self.add_field("resource", f"{img_prefix}_requests_cpu",
                                   str(req_cpu), "cpu", kind, obj_name)
                if req_mem:
                    self.add_field("resource", f"{img_prefix}_requests_memory",
                                   str(req_mem), "memory", kind, obj_name)
            if limits:
                lim_cpu = limits.get("cpu")
                lim_mem = limits.get("memory")
                if lim_cpu:
                    self.add_field("resource", f"{img_prefix}_limits_cpu",
                                   str(lim_cpu), "cpu", kind, obj_name)
                if lim_mem:
                    self.add_field("resource", f"{img_prefix}_limits_memory",
                                   str(lim_mem), "memory", kind, obj_name)

            # Environment variables
            envs = container.get("env", [])
            if envs:
                for env_entry in envs:
                    if not isinstance(env_entry, dict):
                        continue
                    ename = env_entry.get("name", "")
                    if not ename:
                        continue

                    # Sensitive check first
                    if is_sensitive_env_name(ename):
                        e_key = f"{self.app_key}_{ename.lower()}_gen_sensitive"
                        self.add_field("sensitive", e_key, "", "sensitive_env",
                                       kind, obj_name)
                        continue

                    # Skip if valueFrom is present
                    if env_entry.get("valueFrom"):
                        continue

                    evalue = env_entry.get("value", "")
                    if evalue is None:
                        evalue = ""
                    evalue = str(evalue)

                    # Dynamic heuristics
                    if is_dynamic_env(ename, evalue):
                        e_key = f"{self.app_key}_{ename.lower()}"
                        self.add_field("dynamic", e_key, evalue, "env_var",
                                       kind, obj_name)

        # Init containers
        init_containers = template_spec.get("initContainers", [])
        if init_containers:
            for init_container in init_containers:
                if not isinstance(init_container, dict):
                    continue
                iimage = init_container.get("image", "")
                iname = init_container.get("name", "")
                if iimage:
                    i_suffix = iname.replace("-", "_")
                    registry, repository, tag = split_image(iimage)
                    self.add_field("dynamic",
                                   f"{self.app_key}_init_{i_suffix}_image_registry",
                                   registry, "image_registry", kind, obj_name)
                    self.add_field("dynamic",
                                   f"{self.app_key}_init_{i_suffix}_image_repository",
                                   repository, "image_repository", kind, obj_name)
                    self.add_field("dynamic",
                                   f"{self.app_key}_init_{i_suffix}_image_tag",
                                   tag, "image_tag", kind, obj_name)

        # StatefulSet volumeClaimTemplates
        if kind == "StatefulSet":
            vcts = spec.get("volumeClaimTemplates", [])
            if vcts:
                for vct in vcts:
                    if not isinstance(vct, dict):
                        continue
                    vct_name = vct.get("metadata", {}).get("name", "data")
                    vct_spec = vct.get("spec", {})
                    sc = vct_spec.get("storageClassName", "")
                    storage = vct_spec.get("resources", {}).get("requests", {}).get("storage", "")

                    v_suffix = vct_name.replace("-", "_")
                    if sc:
                        self.add_field("dynamic",
                                       f"{self.app_key}_{v_suffix}_storage_class",
                                       str(sc), "storage_class", kind, obj_name)
                    if storage:
                        self.add_field("dynamic",
                                       f"{self.app_key}_{v_suffix}_storage_size",
                                       str(storage), "storage_size", kind, obj_name)

    def _image_prefix(self, obj_name: str, cname: str,
                      multi_workload: bool, container_count: int) -> str:
        """Determine the image key prefix based on workload and container context."""
        if multi_workload:
            w_suffix = workload_suffix(obj_name, self.app_name)
            if w_suffix:
                if container_count > 1:
                    c_suffix = cname.replace("-", "_")
                    return f"{self.app_key}_{w_suffix}_{c_suffix}"
                else:
                    return f"{self.app_key}_{w_suffix}"
            else:
                if container_count > 1:
                    c_suffix = cname.replace("-", "_")
                    return f"{self.app_key}_{c_suffix}"
                else:
                    return self.app_key
        else:
            if container_count > 1:
                c_suffix = cname.replace("-", "_")
                return f"{self.app_key}_{c_suffix}"
            else:
                return self.app_key

    def _analyze_service(self, doc: dict, kind: str, obj_name: str) -> None:
        """Analyze Service - only extract if NodePort/LoadBalancer."""
        spec = doc.get("spec", {})
        svc_type = spec.get("type", "ClusterIP")
        if not svc_type:
            svc_type = "ClusterIP"

        if svc_type in ("NodePort", "LoadBalancer"):
            self.add_field("dynamic", f"{self.app_key}_service_type",
                           svc_type, "string", kind, obj_name)

            if svc_type == "NodePort":
                ports = spec.get("ports", [])
                for npidx, port in enumerate(ports):
                    if not isinstance(port, dict):
                        continue
                    np = port.get("nodePort")
                    np_name = port.get("name", f"port{npidx}")
                    if np is not None:
                        np_suffix = np_name.replace("-", "_")
                        self.add_field("dynamic",
                                       f"{self.app_key}_{np_suffix}_node_port",
                                       str(np), "integer", kind, obj_name)

    def _analyze_secret(self, doc: dict, kind: str, obj_name: str) -> None:
        """Analyze Secret - all data/stringData keys are sensitive."""
        data_keys = list((doc.get("data") or {}).keys())
        sdata_keys = list((doc.get("stringData") or {}).keys())
        all_keys = data_keys + sdata_keys

        for skey in all_keys:
            if not skey:
                continue
            sk_normalized = normalize_key(skey)
            self.add_field("sensitive",
                           f"{self.app_key}_{sk_normalized}_gen_sensitive",
                           "", "sensitive", kind, obj_name)

    def _analyze_configmap(self, doc: dict, kind: str, obj_name: str) -> None:
        """Analyze ConfigMap - flag single-line URL/FQDN values as dynamic."""
        data = doc.get("data") or {}

        for cmkey, cmval in data.items():
            if not cmkey or not cmval:
                continue
            cmval = str(cmval)

            # Skip multi-line values (more than 3 lines)
            if is_multiline(cmval):
                continue

            # Flag URL or FQDN values
            if is_url_or_fqdn(cmval):
                cm_suffix = normalize_key(cmkey)
                self.add_field("dynamic", f"{self.app_key}_{cm_suffix}",
                               cmval, "config_value", kind, obj_name)

    def _analyze_ingress(self, doc: dict, kind: str, obj_name: str) -> None:
        """Analyze Ingress - hosts, TLS, ingressClass are dynamic."""
        spec = doc.get("spec", {})

        # Hosts from rules
        rules = spec.get("rules", [])
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            host = rule.get("host", "")
            if host:
                self.add_field("dynamic", f"{self.app_key}_ingress_host",
                               host, "hostname", kind, obj_name)

        # TLS
        tls_list = spec.get("tls", [])
        for tls in tls_list:
            if not isinstance(tls, dict):
                continue
            secret_name = tls.get("secretName", "")
            if secret_name:
                self.add_field("dynamic", f"{self.app_key}_ingress_tls_secret",
                               secret_name, "string", kind, obj_name)

        # Ingress class (annotation or spec field)
        annotations = doc.get("metadata", {}).get("annotations", {}) or {}
        iclass = annotations.get("kubernetes.io/ingress.class", "")
        if not iclass:
            iclass = spec.get("ingressClassName", "")
        if iclass:
            self.add_field("dynamic", f"{self.app_key}_ingress_class",
                           iclass, "string", kind, obj_name)

    def _analyze_hpa(self, doc: dict, kind: str, obj_name: str) -> None:
        """Analyze HorizontalPodAutoscaler."""
        spec = doc.get("spec", {})

        min_replicas = spec.get("minReplicas")
        max_replicas = spec.get("maxReplicas")

        if min_replicas is not None:
            self.add_field("dynamic", f"{self.app_key}_hpa_min_replicas",
                           str(min_replicas), "integer", kind, obj_name)
        if max_replicas is not None:
            self.add_field("dynamic", f"{self.app_key}_hpa_max_replicas",
                           str(max_replicas), "integer", kind, obj_name)

    def _analyze_pvc(self, doc: dict, kind: str, obj_name: str) -> None:
        """Analyze PersistentVolumeClaim."""
        spec = doc.get("spec", {})

        sc = spec.get("storageClassName", "")
        storage = spec.get("resources", {}).get("requests", {}).get("storage", "")

        if sc:
            self.add_field("dynamic", f"{self.app_key}_storage_class",
                           str(sc), "storage_class", kind, obj_name)
        if storage:
            self.add_field("dynamic", f"{self.app_key}_storage_size",
                           str(storage), "storage_size", kind, obj_name)


# --- Main ---

def main():
    parser = argparse.ArgumentParser(
        description="Analyze rendered K8s manifests and classify fields"
    )
    parser.add_argument("app_name", help="Application name")
    parser.add_argument("--output-dir", default="./output",
                        help="Output directory (default: ./output)")
    parser.add_argument("--kb", default="knowledge-base/fields.yaml",
                        help="Knowledge base YAML path")

    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    kb_path = Path(args.kb) if args.kb else None

    analyzer = Analyzer(args.app_name, output_dir, kb_path)
    result = analyzer.analyze()

    # Write output
    fields_file = output_dir / f"{args.app_name}-fields.json"
    with open(fields_file, "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")

    # Summary
    total = len(result)
    dyn = sum(1 for r in result if r["classification"] == "dynamic")
    res = sum(1 for r in result if r["classification"] == "resource")
    sen = sum(1 for r in result if r["classification"] == "sensitive")
    print(f"  Result: {total} fields ({dyn} dynamic, {res} resource, {sen} sensitive)")
    print(f"  Output: {fields_file}")


if __name__ == "__main__":
    main()
