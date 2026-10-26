#!/bin/bash
set -euo pipefail

ym_root="$(cd "$(dirname "$0")" && pwd)"
ym_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-policy-tests.XXXXXX")"
trap 'rm -rf "$ym_stage"' EXIT

if [ -n "${YOMADO_DEVELOPER_DIR:-}" ]; then
  ym_developer="$YOMADO_DEVELOPER_DIR"
else
  ym_developer="$(xcode-select -p)"
fi
ym_clang="$(DEVELOPER_DIR="$ym_developer" /usr/bin/xcrun --find clang)"
ym_sdk="$(DEVELOPER_DIR="$ym_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

"$ym_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_sdk" -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_root"=. -fmacro-prefix-map="$ym_root"=. \
  -I "$ym_root/app" "$ym_root/tests/PolicyTests.m" -framework Foundation \
  -o "$ym_stage/PolicyTests"
"$ym_stage/PolicyTests"

"$ym_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_sdk" -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_root"=. -fmacro-prefix-map="$ym_root"=. \
  -I "$ym_root/app" "$ym_root/tests/WindowRecoveryTests.m" -framework Foundation \
  -o "$ym_stage/WindowRecoveryTests"
"$ym_stage/WindowRecoveryTests"

"$ym_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_sdk" -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_root"=. -fmacro-prefix-map="$ym_root"=. \
  -I "$ym_root/app" "$ym_root/tests/AppWorkspaceTests.m" -framework Foundation \
  -framework CoreGraphics -o "$ym_stage/AppWorkspaceTests"
"$ym_stage/AppWorkspaceTests"

# Injected workspace window-access adapter; never probes live apps or displays.
bash "$ym_root/scripts/test-app-workspace.sh"

"$ym_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_sdk" -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_root"=. -fmacro-prefix-map="$ym_root"=. \
  -I "$ym_root/app" "$ym_root/tests/InputLeaseTests.m" -framework Foundation \
  -o "$ym_stage/InputLeaseTests"
"$ym_stage/InputLeaseTests"

# Foundation-only update policy and simulated transport tests.
bash "$ym_root/scripts/test-updates.sh"
bash "$ym_root/scripts/test-automatic-updater.sh"
bash "$ym_root/scripts/test-update-workspace-recovery.sh"

# Pure injected backend/controller regressions; never touch live displays.
bash "$ym_root/scripts/test-display-topology.sh"
bash "$ym_root/scripts/test-controller-safety.sh"

bash "$ym_root/scripts/test-panel-presentation.sh"
# Image-only app icon regressions; no application or displays are started.
bash "$ym_root/scripts/test-app-icon.sh"
