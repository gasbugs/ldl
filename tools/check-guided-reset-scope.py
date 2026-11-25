#!/usr/bin/env python3
"""Read-only inventory for the Tenant 03 reset boundary."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "llm-security-guided-course"
MANIFEST = ROOT / "tools/guided-practice-files.tsv"
WORKSPACE = Path.home() / "owasp-llm-practice"
EXPECTED_PRACTICE_FILES = 23


def command(*args):
    return subprocess.check_output(args, text=True, timeout=60).strip()


def aws(service, operation, *args):
    # WSL에서는 AWS CLI의 default chain이 default profile을, EC2에서는
    # instance profile을 선택한다. 특정 profile을 강제하면 EC2 삭제가 막힌다.
    return json.loads(command("aws", service, operation, "--region", "us-east-1",
                              *args, "--output", "json"))


def aws_optional(service, operation, *args, missing):
    process = subprocess.run(
        ("aws", service, operation, "--region", "us-east-1", *args, "--output", "json"),
        text=True, capture_output=True, timeout=60,
    )
    if process.returncode == 0:
        return json.loads(process.stdout or "{}")
    if any(code in process.stderr for code in missing):
        return None
    raise RuntimeError(process.stderr.strip()[-600:] or f"AWS {service} {operation} failed")


def practice_files():
    if not WORKSPACE.is_dir() or WORKSPACE.is_symlink():
        raise RuntimeError("Practice 작업 폴더가 없거나 심볼릭 링크입니다.")
    files = []
    for line in MANIFEST.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        display_id, source, name, services = line.split("|")
        if Path(name).name != name or not source.startswith("guided-labs/"):
            raise RuntimeError("manifest 경로가 예상 범위를 벗어났습니다.")
        path = WORKSPACE / name
        if path.is_symlink() or not path.is_file():
            raise RuntimeError(f"Starter 작업 파일이 없거나 일반 파일이 아닙니다: {name}")
        command("git", "-C", str(ROOT), "cat-file", "-e",
                f"HEAD:llm-security-control-plane/{source}")
        files.append({"mission": display_id, "path": str(path), "services": services.split(",")})
    if (len(files) != EXPECTED_PRACTICE_FILES
            or len({row["path"] for row in files}) != EXPECTED_PRACTICE_FILES):
        raise RuntimeError(f"{EXPECTED_PRACTICE_FILES}개 작업 파일 manifest가 예상과 다릅니다.")
    return files


def docker_resources():
    selector = f"label=com.docker.compose.project={PROJECT}"
    containers = command("docker", "ps", "-a", "--filter", selector,
                         "--format", "{{.Names}}").splitlines()
    volumes = command("docker", "volume", "ls", "--filter", selector,
                      "--format", "{{.Name}}").splitlines()
    if not containers or not volumes:
        raise RuntimeError("Tenant 03 Docker project가 실행 중인 기존 환경과 일치하지 않습니다.")
    if any(not name.startswith("llm-security-guided-") for name in containers):
        raise RuntimeError("예상 범위 밖의 컨테이너가 Tenant 03 label에 포함됐습니다.")
    if any(not name.startswith(PROJECT + "_") for name in volumes):
        raise RuntimeError("예상 범위 밖의 volume이 Tenant 03 label에 포함됐습니다.")
    return {"project": PROJECT, "containers": containers, "volumes": volumes}


def aws_resources():
    identity = aws("sts", "get-caller-identity")
    account = identity["Account"]
    if len(account) != 12 or not account.isdigit():
        raise RuntimeError("AWS 계정 번호를 확인하지 못했습니다.")
    prefixes = (f"owasp-llm-03-{account}", f"owasp-guided-p03-{account}")
    guardrail = f"owasp-guided-p04-{account}"
    bases = [row for row in aws("bedrock-agent", "list-knowledge-bases").get("knowledgeBaseSummaries", [])
             if any(row.get("name", "").startswith(prefix) for prefix in prefixes)]
    guards = [row for row in aws("bedrock", "list-guardrails").get("guardrails", [])
              if row.get("name") == guardrail]
    bucket_names = [f"{prefix}-source" for prefix in prefixes]
    buckets = [name for name in bucket_names if aws_optional(
        "s3api", "head-bucket", "--bucket", name, "--expected-bucket-owner", account,
        missing=("404", "NoSuchBucket")) is not None]
    vector_names = [f"{prefix}-vectors" for prefix in prefixes]
    vectors = [result for name in vector_names if (result := aws_optional(
        "s3vectors", "get-vector-bucket", "--vector-bucket-name", name,
        missing=("NotFoundException", "ResourceNotFoundException"))) is not None]
    role_names = [f"{prefix}-knowledge-base-role" if prefix == prefixes[0]
                  else f"{prefix}-kb-role" for prefix in prefixes]
    roles = [name for name in role_names if aws_optional(
        "iam", "get-role", "--role-name", name, missing=("NoSuchEntity",)) is not None]
    return {"account": account, "region": "us-east-1", "knowledge_bases": bases,
            "guardrails": guards, "source_buckets": buckets,
            "vector_buckets": vectors, "roles": roles}


def main():
    inventory = {"practice_files": practice_files(), "docker": docker_resources(), "aws": aws_resources()}
    inventory["summary"] = {
        "practice_files": len(inventory["practice_files"]),
        "containers": len(inventory["docker"]["containers"]),
        "volumes": len(inventory["docker"]["volumes"]),
        "aws_resources": sum(len(value) for key, value in inventory["aws"].items()
                             if isinstance(value, list)),
    }
    print(json.dumps(inventory, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
