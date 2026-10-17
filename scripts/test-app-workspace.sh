#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yomado-app-workspace-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 -Iapp \
  tests/AppWorkspaceAccessTests.m app/AppWorkspaceAccess.m app/UpdateWorkspaceRecovery.m \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -o "$BUILD_DIR/app-workspace-access-tests"
"$BUILD_DIR/app-workspace-access-tests"
clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 -Iapp \
  tests/AppWorkspaceRuntimeTests.m app/AppWorkspace.m app/AppWorkspaceAccess.m \
  app/UpdateWorkspaceRecovery.m \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -o "$BUILD_DIR/app-workspace-runtime-tests"
"$BUILD_DIR/app-workspace-runtime-tests"
