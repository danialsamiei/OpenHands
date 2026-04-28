#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.qadr}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

AGENT_SERVER_BASE_IMAGE_REPOSITORY="${AGENT_SERVER_BASE_IMAGE_REPOSITORY:-ghcr.io/openhands/agent-server}"
AGENT_SERVER_BASE_IMAGE_TAG="${AGENT_SERVER_BASE_IMAGE_TAG:-1.12.0-python}"
AGENT_SERVER_IMAGE_REPOSITORY="${AGENT_SERVER_IMAGE_REPOSITORY:-gantor/openhands-agent-server}"
AGENT_SERVER_IMAGE_TAG="${AGENT_SERVER_IMAGE_TAG:-qadr-pw}"

docker build \
  -f "$ROOT_DIR/deploy/qadr-agent-server.Dockerfile" \
  --build-arg "BASE_REPOSITORY=$AGENT_SERVER_BASE_IMAGE_REPOSITORY" \
  --build-arg "BASE_TAG=$AGENT_SERVER_BASE_IMAGE_TAG" \
  -t "${AGENT_SERVER_IMAGE_REPOSITORY}:${AGENT_SERVER_IMAGE_TAG}" \
  "$ROOT_DIR"
