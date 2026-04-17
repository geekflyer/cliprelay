#!/usr/bin/env bash
# Public entrypoint for the automated BLE smoke test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/hardware-smoke-test-runner.sh" "$@"
