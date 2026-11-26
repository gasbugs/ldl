"""Resolve Compose and check the EC2 browser listeners without starting services."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKENS = (
    "APPLICATION_INTERNAL_TOKEN", "PRESIDIO_INTERNAL_TOKEN", "BEDROCK_GATEWAY_TOKEN",
    "AUTH_ADMIN_TOKEN", "GRAFANA_ADMIN_PASSWORD", "LLM_MONITOR_ADMIN_TOKEN",
    "LLM_MONITOR_TOKEN", "RETRIEVAL_SERVICE_TOKEN", "TELEMETRY_HMAC_KEY",
    "TELEMETRY_INGEST_TOKEN",
)


def compose(relative):
    env = {key: value for key, value in os.environ.items()
           if not key.endswith(("_HOST_PORT", "_BIND_ADDRESS"))}
    env.update({key: "port-contract-fixture" for key in TOKENS})
    env["GRAFANA_ADMIN_USER"] = "admin"
    output = subprocess.check_output(
        ["docker", "compose", "--env-file", "/dev/null", "-f", str(ROOT / relative),
         "config", "--format", "json"], env=env, text=True)
    return json.loads(output)["services"]


class BrowserPortContract(unittest.TestCase):
    def test_non_root_services_have_writable_state_mounts(self):
        services = compose("llm-security-control-plane/compose.yaml")
        expected = {
            "bedrock-gateway": ("/app/state", ".state/bedrock-gateway"),
            "application": ("/app/state", ".state/application-auth"),
        }
        for name, (target, source_suffix) in expected.items():
            volumes = services[name].get("volumes", [])
            mount = next((item for item in volumes if item.get("target") == target), None)
            self.assertIsNotNone(mount, name)
            self.assertEqual(mount.get("type"), "bind", name)
            self.assertTrue(mount.get("source", "").endswith(source_suffix), name)
            self.assertFalse(mount.get("read_only", False), name)

    def test_evaluation_recovery_supports_ec2_instance_role(self):
        script = (ROOT / "llm-security-control-plane/deploy/prepare-evaluation-environment.sh").read_text()
        self.assertIn("USE_EC2_INSTANCE_ROLE=false", script)
        self.assertIn("AWS_EC2_METADATA_DISABLED=false", script)
        self.assertIn("USE_EC2_INSTANCE_ROLE=$USE_EC2_INSTANCE_ROLE", script)
        self.assertIn('mkdir -p "$ROOT/.state/bedrock-gateway"', script)
        self.assertIn("module08-compose.env module08-aws.env module10-compose.env", script)
        self.assertNotIn('mv "$ROOT/.state" "$BACKUP_DIR"', script)

    def test_application_is_the_only_public_control_plane_service(self):
        services = compose("llm-security-control-plane/compose.yaml")
        self.assertNotIn("build", services["bedrock-gateway"])
        self.assertEqual(services["bedrock-gateway"]["image"], "ghcr.io/gasbugs/ldl-bedrock-gateway:v2026.11.23.19.05")
        for name, service in services.items():
            for port in service.get("ports", []):
                if name == "application":
                    self.assertEqual((int(port["published"]), port["host_ip"]), (9016, "0.0.0.0"))
                else:
                    self.assertEqual(port["host_ip"], "127.0.0.1", name)

    def test_grafana_is_the_only_public_monitoring_service(self):
        services = compose("examples/security-monitoring/compose.yaml")
        for name, service in services.items():
            for port in service.get("ports", []):
                if name == "grafana":
                    self.assertEqual((int(port["published"]), port["host_ip"]), (9017, "0.0.0.0"))
                else:
                    self.assertEqual(port["host_ip"], "127.0.0.1", name)

    def test_browser_links_use_the_current_ec2_hostname(self):
        html = (ROOT / "llm-security-control-plane/application-gateway/index.html").read_text()
        self.assertNotIn('href="http://127.0.0.1', html)
        self.assertNotIn("http://127.0.0.1:3200", html)
        self.assertIn("new URL(window.location.href)", html)
        self.assertIn("grafanaBase.port = '9017'", html)


if __name__ == "__main__":
    unittest.main()
