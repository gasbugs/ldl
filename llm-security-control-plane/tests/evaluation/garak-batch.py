"""Select a pair from the configured Probe pool, then validate every response."""
import sys
import json
from pathlib import Path
from garak import cli, _config
from garak.probes import promptinject
from garak.generators.rest import RestGenerator

batch = int(sys.argv[1])
if batch < 0:
    raise ValueError("batch must be non-negative")
probe_type = promptinject.HijackHateHumans
original_init = probe_type.__init__


def bounded_init(self, config_root=_config):
    original_init(self, config_root=config_root)
    start = 2 * batch
    if start >= len(self.prompts):
        raise ValueError("batch is outside the configured Probe pool")
    selected = self.prompts[start:start + 2]
    by_prompt = {item["prompt"]: item for item in self.pi_prompts}
    self.prompts = selected
    self.pi_prompts = [by_prompt[prompt] for prompt in selected]


rest_init = RestGenerator.__init__


def no_retry_init(self, uri=None, config_root=_config):
    rest_init(self, uri=uri, config_root=config_root)
    self.retry_5xx = False


RestGenerator.__init__ = no_retry_init
probe_type.__init__ = bounded_init
cli.main(sys.argv[2:])

rows = [json.loads(line) for line in Path(_config.transient.reportfile.name).read_text().splitlines()]
attempts = [row for row in rows if row.get("entry_type") == "attempt" and row.get("status") == 2]
if len(attempts) != 2:
    raise RuntimeError("ERR: expected two completed Attempts; inspect the report")
for attempt in attempts:
    if len(attempt.get("outputs", [])) != _config.run.generations:
        raise RuntimeError("ERR: missing generated responses")
    for output in attempt["outputs"]:
        response = json.loads(output["text"])
        if response.get("application_decision") not in ("allow", "block"):
            raise RuntimeError("ERR: Application did not complete a security decision")
        main = next((s for s in response.get("guardrail", {}).get("stages", []) if s["stage"] == "bedrock_main"), {})
        if response.get("upstream_called") and main.get("stop_reason") != "stop":
            raise RuntimeError("ERR: Main response is incomplete")
