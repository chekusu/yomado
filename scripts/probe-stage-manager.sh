#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer an explicit probe temp root, then TMPDIR, then /tmp. Never hard-code a
# machine-specific absolute path so --self-test works on other hosts.
PROBE_TEMP_ROOT="${YOMADO_PROBE_TEMP_ROOT:-${TMPDIR:-/tmp}}"
PROBE_TEMP_ROOT="${PROBE_TEMP_ROOT%/}"
mkdir -p "$PROBE_TEMP_ROOT"
BUILD_DIR="$(mktemp -d "${PROBE_TEMP_ROOT}/yomado-stage-probe.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I app \
  tests/StageManagerWindowProbe.m app/UpdateWorkspaceRecovery.m \
  -framework AppKit -framework CoreGraphics -framework ApplicationServices \
  -o "$BUILD_DIR/stage-manager-probe"
"$BUILD_DIR/stage-manager-probe" "$@"
