#!/usr/bin/env bash
# Wrapper that delegates to the automated hardware smoke test script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/hardware-smoke-test-auto.sh" "$@"
