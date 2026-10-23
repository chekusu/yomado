#!/bin/bash
set -euo pipefail

# Separate from the pure policy tests: AppKit requires a macOS WindowServer
# session. The fixture stays hidden and never reads or moves real app windows.
if [ "$(uname -s)" != Darwin ]; then
  printf 'Layout tests require macOS and a WindowServer session.\n' >&2
  exit 1
fi

ym_layout_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_layout_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-layout-tests.XXXXXX")"
trap 'rm -rf "$ym_layout_stage"' EXIT

if [ -n "${YOMADO_DEVELOPER_DIR:-}" ]; then
  ym_layout_developer="$YOMADO_DEVELOPER_DIR"
else
  ym_layout_developer="$(xcode-select -p)"
fi
ym_layout_clang="$(DEVELOPER_DIR="$ym_layout_developer" /usr/bin/xcrun --find clang)"
ym_layout_sdk="$(DEVELOPER_DIR="$ym_layout_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

"$ym_layout_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_layout_sdk" \
  -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_layout_root"=. -fmacro-prefix-map="$ym_layout_root"=. \
  -I "$ym_layout_root/app" "$ym_layout_root/tests/WorkspaceLayoutTests.m" \
  -framework AppKit -framework QuartzCore -o "$ym_layout_stage/WorkspaceLayoutTests"
"$ym_layout_stage/WorkspaceLayoutTests"

# The overview test builds the production controller panel from synthetic
# display snapshots in preview mode.
ym_layout_sparkle="$("$ym_layout_root/scripts/fetch-sparkle.sh")"
"$ym_layout_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_layout_sdk" \
  -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_layout_root"=. -fmacro-prefix-map="$ym_layout_root"=. \
  -I "$ym_layout_root/bridge" -I "$ym_layout_root/app" "$ym_layout_root/tests/OverviewLayoutTests.m" \
  "$ym_layout_root/app/ControlUI.m" "$ym_layout_root/app/WindowRecovery.m" \
  "$ym_layout_root/app/UpdateChecker.m" "$ym_layout_root/app/MenuBarIcon.m" "$ym_layout_root/app/PanelPresentation.m" \
  "$ym_layout_root/app/AutomaticUpdater.m" "$ym_layout_root/app/UpdateWorkspaceRecovery.m" \
  "$ym_layout_root/app/AppWorkspace.m" "$ym_layout_root/app/AppWorkspaceView.m" "$ym_layout_root/app/InputLease.m" \
  "$ym_layout_root/bridge/VDVirtualDisplay.m" "$ym_layout_root/bridge/YMDisplayTopology.m" \
  -framework AppKit -framework CoreGraphics -framework IOKit -framework Carbon -framework ApplicationServices \
  -framework QuartzCore -framework ColorSync \
  -F "$ym_layout_sparkle" -framework Sparkle "-Wl,-rpath,$ym_layout_sparkle" \
  -o "$ym_layout_stage/OverviewLayoutTests"
"$ym_layout_stage/OverviewLayoutTests"
