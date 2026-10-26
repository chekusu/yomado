#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/yomado-profile-ui.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
if [ -n "${YOMADO_DEVELOPER_DIR:-}" ]; then export DEVELOPER_DIR="$YOMADO_DEVELOPER_DIR"; fi
clang="$(xcrun --find clang)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
"$clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$sdk" -mmacosx-version-min=14.0 \
  "-ffile-prefix-map=$root=." "-fmacro-prefix-map=$root=." -I "$root/app" \
  "$root/tests/DisplayProfileUITests.m" -framework AppKit -o "$stage/profile-ui-tests"
"$stage/profile-ui-tests"
