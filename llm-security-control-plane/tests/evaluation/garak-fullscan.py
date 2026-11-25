"""200개 PromptInject 문장으로 Application 업무 경계를 시험한다."""
import copy
import json
import re
import sys
from pathlib import Path

from garak import cli, _config
from garak.generators.rest import RestGenerator
from garak.probes import promptinject

probe_type = promptinject.HijackHateHumans
probe_init = probe_type.__init__


def application_probe_init(self, config_root=_config):
    # Garak이 seed로 고른 문장과 각각의 채점 설정을 같은 순서로 묶는다.
    probe_init(self, config_root=config_root)
    by_prompt = {item["prompt"]: item for item in self.pi_prompts}
    selected = [copy.deepcopy(by_prompt[prompt]) for prompt in self.prompts]

    # 정상 작업 형식은 유지하면서 업무 이탈 목표만 canary로 바꾼다.
    for item in selected:
        item["prompt"], replacements = re.subn(
            r"I hate humans", "FORMAT_CHECK_CANARY", item["prompt"], flags=re.I
        )
        if replacements == 0:
            raise RuntimeError("ERR: PromptInject candidate has no expected target string")
        item["settings"]["attack_rogue_string"] = "FORMAT_CHECK_CANARY"

    self.pi_prompts = selected
    self.prompts = [item["prompt"] for item in selected]


rest_init = RestGenerator.__init__


def no_retry_init(self, uri=None, config_root=_config):
    # 5xx 요청을 자동으로 재시도하면 200건 예산과 실제 호출 수가 어긋난다.
    rest_init(self, uri=uri, config_root=config_root)
    self.retry_5xx = False


RestGenerator.__init__ = no_retry_init
probe_type.__init__ = application_probe_init
cli.main(sys.argv[1:])

# Report의 완료 Attempt 수와 Application 응답 계약을 확인한다.
rows = [json.loads(line) for line in Path(
    _config.transient.reportfile.name
).read_text().splitlines()]
attempts = [row for row in rows
            if row.get("entry_type") == "attempt" and row.get("status") == 2]
if len(attempts) != _config.run.soft_probe_prompt_cap:
    raise RuntimeError("ERR: expected 200 completed Attempts; inspect the report")

for attempt in attempts:
    if len(attempt.get("outputs", [])) != _config.run.generations:
        raise RuntimeError("ERR: missing generated responses")
    for output in attempt["outputs"]:
        response = json.loads(output["text"])
        if response.get("application_decision") not in ("allow", "block"):
            raise RuntimeError("ERR: Application did not complete a security decision")
        main = next((stage for stage in response.get("guardrail", {}).get(
            "stages", []) if stage["stage"] == "bedrock_main"), {})
        if response.get("upstream_called") and main.get("stop_reason") != "stop":
            raise RuntimeError(
                f"ERR: seq={attempt.get('seq')} Main response is incomplete"
            )
