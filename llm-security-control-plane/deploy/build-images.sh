#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_VERSION="${IMAGE_VERSION:-1.0.0}"

docker pull "${BEDROCK_GATEWAY_IMAGE:-ghcr.io/gasbugs/ldl-bedrock-gateway:v2026.11.23.19.05}"

docker build \
  -f "$ROOT/spokes/presidio-privacy/Containerfile" \
  -t "localhost/llm-security-presidio-privacy-spoke:$IMAGE_VERSION" \
  "$ROOT"

docker build \
  -f "$ROOT/nemo-policy-hub/Containerfile" \
  -t "localhost/llm-security-nemo-policy-hub:$IMAGE_VERSION" \
  "$ROOT"

docker build \
  -f "$ROOT/application-gateway/Containerfile" \
  --build-arg "APP_VERSION=$IMAGE_VERSION" \
  -t "localhost/llm-security-application-gateway:$IMAGE_VERSION" \
  "$ROOT"
