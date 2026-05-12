#!/usr/bin/env bash
# scripts/test-bootstrap-local.sh — run install/run.sh in a throwaway
# Ubuntu 24.04 container with the repo mounted. ~60-90 seconds.
#
# Requires Docker on the host. Not part of CI by default.
#
# Usage: bash scripts/test-bootstrap-local.sh [--keep] [--nopasswd]
#   --keep      Don't remove the container on exit (debug).
#   --nopasswd  Set JINX_NOPASSWD=1 during the run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ubuntu:24.04"
CONTAINER="jinx-bootstrap-test-$$"
KEEP=0
NOPASSWD_ENV=()

for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --nopasswd) NOPASSWD_ENV=(-e JINX_NOPASSWD=1) ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

cleanup() {
    if [[ $KEEP -eq 0 ]]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    else
        echo "Container preserved: $CONTAINER"
    fi
}
trap cleanup EXIT

echo "==> Pulling $IMAGE (cached after first run)"
docker pull -q "$IMAGE" >/dev/null

echo "==> Starting container $CONTAINER"
# --privileged: required for systemd + ufw inside the container.
# tmpfs /run /run/lock: systemd needs writable runtime dirs.
docker run -d --name "$CONTAINER" --privileged \
    --tmpfs /run --tmpfs /run/lock \
    -v "${REPO_ROOT}:/opt/jinx:ro" \
    "${NOPASSWD_ENV[@]}" \
    "$IMAGE" sleep infinity >/dev/null

# Install systemd inside the container so unit-management commands work.
echo "==> Installing systemd + minimal prereqs in container"
docker exec "$CONTAINER" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends systemd systemd-sysv dbus sudo
'

echo "==> Running install/run.sh"
docker exec "${NOPASSWD_ENV[@]}" "$CONTAINER" \
    bash -c 'cd /opt/jinx && bash install/run.sh'

echo "==> All install steps completed"
echo "==> Tail of /var/log/jinx-bootstrap.log:"
docker exec "$CONTAINER" tail -30 /var/log/jinx-bootstrap.log

# Final per-task assertions are made by install/90-verify.sh; this harness
# just confirms the chain exits zero (success).
echo
echo "SMOKE TEST PASSED"
