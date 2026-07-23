"""
Unit tests for the knowledge-based field analyzer.

Tests the core classification logic: image splitting, workload suffix
derivation, env var heuristics, and per-Kind field extraction.
"""

import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
from analyzer import (
    Analyzer,
    is_dynamic_env,
    is_sensitive_env_name,
    is_url_or_fqdn,
    split_image,
    workload_suffix,
)

# --- Unit tests for utility functions ---


class TestSplitImage:
    """Tests for container image reference parsing."""

    def test_standard_image(self):
        reg, repo, tag = split_image("ghcr.io/stefanprodan/podinfo:6.7.1")
        assert reg == "ghcr.io"
        assert repo == "stefanprodan/podinfo"
        assert tag == "6.7.1"

    def test_dockerhub_image_no_registry(self):
        reg, repo, tag = split_image("library/nginx:1.25")
        assert reg == ""
        assert repo == "library/nginx"
        assert tag == "1.25"

    def test_image_with_digest(self):
        reg, repo, tag = split_image(
            "gcr.io/app/image@sha256:abc123"
        )
        assert reg == "gcr.io"
        assert repo == "app/image"
        assert tag == "sha256:abc123"

    def test_image_no_tag(self):
        reg, repo, tag = split_image("docker.io/bitnami/rabbitmq")
        assert reg == "docker.io"
        assert repo == "bitnami/rabbitmq"
        assert tag == "latest"

    def test_simple_image_no_registry(self):
        reg, repo, tag = split_image("nginx:alpine")
        assert reg == ""
        assert repo == "nginx"
        assert tag == "alpine"

    def test_registry_with_port(self):
        reg, repo, tag = split_image("localhost:5000/myapp:v1")
        assert reg == "localhost:5000"
        assert repo == "myapp"
        assert tag == "v1"

    def test_nested_repository_path(self):
        reg, repo, tag = split_image("quay.io/prometheus/alertmanager:v0.27.0")
        assert reg == "quay.io"
        assert repo == "prometheus/alertmanager"
        assert tag == "v0.27.0"


class TestWorkloadSuffix:
    """Tests for multi-workload key prefix derivation."""

    def test_same_as_app(self):
        assert workload_suffix("hazelcast", "hazelcast") == ""

    def test_prefixed_name(self):
        assert workload_suffix("hazelcast-mancenter", "hazelcast") == "mancenter"

    def test_multi_segment_suffix(self):
        assert workload_suffix("myapp-worker-gpu", "myapp") == "worker_gpu"

    def test_unrelated_name(self):
        assert workload_suffix("redis-master", "hazelcast") == "redis_master"

    def test_exact_prefix_but_no_dash(self):
        assert workload_suffix("hazelcastx", "hazelcast") == "hazelcastx"


class TestEnvVarHeuristics:
    """Tests for environment variable classification."""

    def test_sensitive_password(self):
        assert is_sensitive_env_name("RABBITMQ_PASSWORD") is True

    def test_sensitive_api_key(self):
        assert is_sensitive_env_name("STRIPE_API_KEY") is True

    def test_sensitive_token(self):
        assert is_sensitive_env_name("AUTH_TOKEN") is True

    def test_sensitive_secret(self):
        assert is_sensitive_env_name("CLIENT_SECRET") is True

    def test_not_sensitive_host(self):
        assert is_sensitive_env_name("DATABASE_HOST") is False

    def test_not_sensitive_port(self):
        assert is_sensitive_env_name("SERVICE_PORT") is False

    def test_dynamic_url(self):
        assert is_dynamic_env("BACKEND_URL", "https://api.example.com") is True

    def test_dynamic_http(self):
        assert is_dynamic_env("WEBHOOK", "http://hooks.internal.io/v1") is True

    def test_dynamic_host_suffix(self):
        assert is_dynamic_env("DATABASE_HOST", "db.prod.internal") is True

    def test_static_intra_cluster(self):
        assert is_dynamic_env("REDIS_ADDR", "redis:6379") is False

    def test_static_numeric(self):
        assert is_dynamic_env("TIMEOUT", "30") is False

    def test_dynamic_endpoint(self):
        assert is_dynamic_env("API_ENDPOINT", "grpc.service.local") is True


class TestUrlFqdnDetection:
    """Tests for ConfigMap URL/FQDN heuristic."""

    def test_https_url(self):
        assert is_url_or_fqdn("https://grafana.example.com") is True

    def test_http_url(self):
        assert is_url_or_fqdn("http://prometheus:9090") is True

    def test_fqdn(self):
        assert is_url_or_fqdn("api.example.com") is True

    def test_fqdn_with_port(self):
        assert is_url_or_fqdn("db.internal.io:5432") is True

    def test_plain_string(self):
        assert is_url_or_fqdn("just-a-string") is False

    def test_number(self):
        assert is_url_or_fqdn("8080") is False


# --- Integration tests for per-Kind analyzers ---


def make_rendered_yaml(docs: list[dict], tmp_dir: Path, app_name: str) -> Path:
    """Write a multi-document YAML file for testing."""
    rendered = tmp_dir / f"{app_name}-rendered.yaml"
    with open(rendered, "w") as f:
        yaml.dump_all(docs, f, default_flow_style=False)
    return rendered


class TestDeploymentAnalysis:
    """Tests for Deployment field extraction."""

    def test_single_deployment(self, tmp_path):
        doc = {
            "kind": "Deployment",
            "metadata": {"name": "podinfo"},
            "spec": {
                "replicas": 2,
                "template": {
                    "spec": {
                        "containers": [{
                            "name": "podinfo",
                            "image": "ghcr.io/stefanprodan/podinfo:6.7.1",
                            "resources": {
                                "requests": {"cpu": "100m", "memory": "64Mi"},
                                "limits": {"cpu": "500m", "memory": "128Mi"},
                            },
                        }]
                    }
                },
            },
        }
        make_rendered_yaml([doc], tmp_path, "podinfo")
        kb_path = Path("knowledge-base/fields.yaml")

        analyzer = Analyzer("podinfo", tmp_path, kb_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "podinfo_replicas" in keys
        assert "podinfo_image_registry" in keys
        assert "podinfo_image_repository" in keys
        assert "podinfo_image_tag" in keys
        assert "podinfo_requests_cpu" in keys
        assert "podinfo_limits_memory" in keys

        img_reg = next(f for f in result if f["key"] == "podinfo_image_registry")
        assert img_reg["value"] == "ghcr.io"
        assert img_reg["classification"] == "dynamic"
        assert img_reg["type"] == "image_registry"

        replicas = next(f for f in result if f["key"] == "podinfo_replicas")
        assert replicas["value"] == "2"
        assert replicas["type"] == "integer"

    def test_multi_container_deployment(self, tmp_path):
        doc = {
            "kind": "Deployment",
            "metadata": {"name": "myapp"},
            "spec": {
                "replicas": 1,
                "template": {
                    "spec": {
                        "containers": [
                            {"name": "app", "image": "myapp:v1"},
                            {"name": "sidecar", "image": "envoy:1.30"},
                        ]
                    }
                },
            },
        }
        make_rendered_yaml([doc], tmp_path, "myapp")
        analyzer = Analyzer("myapp", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "myapp_app_image_tag" in keys
        assert "myapp_sidecar_image_tag" in keys

    def test_sensitive_env_extraction(self, tmp_path):
        doc = {
            "kind": "Deployment",
            "metadata": {"name": "backend"},
            "spec": {
                "replicas": 1,
                "template": {
                    "spec": {
                        "containers": [{
                            "name": "backend",
                            "image": "backend:latest",
                            "env": [
                                {"name": "DB_PASSWORD", "value": "secret123"},
                                {"name": "API_KEY", "value": "key-abc"},
                                {"name": "LOG_LEVEL", "value": "info"},
                            ],
                        }]
                    }
                },
            },
        }
        make_rendered_yaml([doc], tmp_path, "backend")
        analyzer = Analyzer("backend", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "backend_db_password_gen_sensitive" in keys
        assert "backend_api_key_gen_sensitive" in keys
        assert "backend_log_level" not in keys  # not dynamic

    def test_dynamic_env_url(self, tmp_path):
        doc = {
            "kind": "Deployment",
            "metadata": {"name": "worker"},
            "spec": {
                "replicas": 1,
                "template": {
                    "spec": {
                        "containers": [{
                            "name": "worker",
                            "image": "worker:v1",
                            "env": [
                                {"name": "CALLBACK_URL", "value": "https://hooks.example.com/v1"},
                                {"name": "REDIS_HOST", "value": "redis:6379"},
                            ],
                        }]
                    }
                },
            },
        }
        make_rendered_yaml([doc], tmp_path, "worker")
        analyzer = Analyzer("worker", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "worker_callback_url" in keys  # URL → dynamic
        assert "worker_redis_host" not in keys  # intra-cluster → static


class TestStatefulSetAnalysis:
    """Tests for StatefulSet-specific fields."""

    def test_volume_claim_templates(self, tmp_path):
        doc = {
            "kind": "StatefulSet",
            "metadata": {"name": "rabbitmq"},
            "spec": {
                "replicas": 3,
                "template": {
                    "spec": {
                        "containers": [{
                            "name": "rabbitmq",
                            "image": "rabbitmq:3.13",
                        }]
                    }
                },
                "volumeClaimTemplates": [{
                    "metadata": {"name": "data"},
                    "spec": {
                        "storageClassName": "gp3",
                        "resources": {"requests": {"storage": "10Gi"}},
                    },
                }],
            },
        }
        make_rendered_yaml([doc], tmp_path, "rabbitmq")
        analyzer = Analyzer("rabbitmq", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "rabbitmq_data_storage_class" in keys
        assert "rabbitmq_data_storage_size" in keys

        sc = next(f for f in result if f["key"] == "rabbitmq_data_storage_class")
        assert sc["value"] == "gp3"
        assert sc["type"] == "storage_class"


class TestMultiWorkloadAnalysis:
    """Tests for multi-Deployment/StatefulSet charts."""

    def test_workload_suffix_derivation(self, tmp_path):
        docs = [
            {
                "kind": "StatefulSet",
                "metadata": {"name": "hazelcast"},
                "spec": {
                    "replicas": 3,
                    "template": {"spec": {"containers": [
                        {"name": "hazelcast", "image": "hazelcast/hazelcast:5.4"}
                    ]}},
                },
            },
            {
                "kind": "StatefulSet",
                "metadata": {"name": "hazelcast-mancenter"},
                "spec": {
                    "replicas": 1,
                    "template": {"spec": {"containers": [
                        {"name": "mancenter", "image": "hazelcast/management-center:5.4"}
                    ]}},
                },
            },
        ]
        make_rendered_yaml(docs, tmp_path, "hazelcast")
        analyzer = Analyzer("hazelcast", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "hazelcast_replicas" in keys
        assert "hazelcast_mancenter_replicas" in keys
        assert "hazelcast_image_tag" in keys
        assert "hazelcast_mancenter_image_tag" in keys


class TestServiceAnalysis:
    """Tests for Service field extraction."""

    def test_clusterip_is_static(self, tmp_path):
        doc = {
            "kind": "Service",
            "metadata": {"name": "myapp"},
            "spec": {"type": "ClusterIP", "ports": [{"port": 80}]},
        }
        make_rendered_yaml([doc], tmp_path, "myapp")
        analyzer = Analyzer("myapp", tmp_path)
        result = analyzer.analyze()
        assert len(result) == 0

    def test_nodeport_is_dynamic(self, tmp_path):
        doc = {
            "kind": "Service",
            "metadata": {"name": "myapp"},
            "spec": {
                "type": "NodePort",
                "ports": [{"name": "http", "port": 80, "nodePort": 30080}],
            },
        }
        make_rendered_yaml([doc], tmp_path, "myapp")
        analyzer = Analyzer("myapp", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "myapp_service_type" in keys
        assert "myapp_http_node_port" in keys


class TestSecretAnalysis:
    """Tests for Secret field extraction."""

    def test_all_keys_are_sensitive(self, tmp_path):
        doc = {
            "kind": "Secret",
            "metadata": {"name": "myapp-creds"},
            "data": {"username": "YWRtaW4=", "password": "cGFzcw=="},
            "stringData": {"api-token": "tok-123"},
        }
        make_rendered_yaml([doc], tmp_path, "myapp")
        analyzer = Analyzer("myapp", tmp_path)
        result = analyzer.analyze()

        assert len(result) == 3
        for f in result:
            assert f["classification"] == "sensitive"
            assert f["key"].endswith("_gen_sensitive")


class TestConfigMapAnalysis:
    """Tests for ConfigMap URL detection heuristic."""

    def test_url_value_detected(self, tmp_path):
        doc = {
            "kind": "ConfigMap",
            "metadata": {"name": "myapp-config"},
            "data": {
                "api_endpoint": "https://api.example.com/v2",
                "log_level": "debug",
                "timeout": "30",
            },
        }
        make_rendered_yaml([doc], tmp_path, "myapp")
        analyzer = Analyzer("myapp", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "myapp_api_endpoint" in keys
        assert "myapp_log_level" not in keys
        assert "myapp_timeout" not in keys

    def test_multiline_value_skipped(self, tmp_path):
        doc = {
            "kind": "ConfigMap",
            "metadata": {"name": "myapp-config"},
            "data": {
                "config.xml": "line1\nline2\nline3\nline4\nline5",
            },
        }
        make_rendered_yaml([doc], tmp_path, "myapp")
        analyzer = Analyzer("myapp", tmp_path)
        result = analyzer.analyze()
        assert len(result) == 0


class TestIngressAnalysis:
    """Tests for Ingress field extraction."""

    def test_host_and_tls(self, tmp_path):
        doc = {
            "kind": "Ingress",
            "metadata": {"name": "myapp", "annotations": {}},
            "spec": {
                "ingressClassName": "nginx",
                "rules": [{"host": "app.example.com"}],
                "tls": [{"secretName": "app-tls", "hosts": ["app.example.com"]}],
            },
        }
        make_rendered_yaml([doc], tmp_path, "myapp")
        analyzer = Analyzer("myapp", tmp_path)
        result = analyzer.analyze()

        keys = {f["key"] for f in result}
        assert "myapp_ingress_host" in keys
        assert "myapp_ingress_tls_secret" in keys
        assert "myapp_ingress_class" in keys


class TestDeduplication:
    """Tests for field deduplication behavior."""

    def test_duplicate_keys_keep_first(self, tmp_path):
        docs = [
            {
                "kind": "Deployment",
                "metadata": {"name": "app"},
                "spec": {
                    "replicas": 2,
                    "template": {"spec": {"containers": [
                        {"name": "app", "image": "app:v1"}
                    ]}},
                },
            },
            {
                "kind": "Deployment",
                "metadata": {"name": "app"},
                "spec": {
                    "replicas": 3,
                    "template": {"spec": {"containers": [
                        {"name": "app", "image": "app:v2"}
                    ]}},
                },
            },
        ]
        make_rendered_yaml(docs, tmp_path, "app")
        analyzer = Analyzer("app", tmp_path)
        result = analyzer.analyze()

        replicas = [f for f in result if f["key"] == "app_replicas"]
        assert len(replicas) == 1
        assert replicas[0]["value"] == "2"  # first occurrence wins
