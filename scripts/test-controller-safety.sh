#!/bin/bash
set -euo pipefail
ym_ci_source="$(cd "$(dirname "$0")" && pwd -P)"
ym_ci_production="$(cd "$ym_ci_source/.." && pwd -P)"
ym_ci_sparkle="$("$ym_ci_production/scripts/fetch-sparkle.sh")"
ym_ci_tmp="$(mktemp -d "${TMPDIR:-/tmp}/yomado-controller-tests.XXXXXX")"
trap 'rm -rf "$ym_ci_tmp"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g0 -mmacosx-version-min=14.0 \
  -I "$ym_ci_production/bridge" -I "$ym_ci_production/app" \
  "$ym_ci_production/tests/ControllerSafetyTests.m" \
  "$ym_ci_production/app/ControlUI.m" "$ym_ci_production/app/WindowRecovery.m" \
  "$ym_ci_production/app/UpdateChecker.m" "$ym_ci_production/app/MenuBarIcon.m" "$ym_ci_production/app/PanelPresentation.m" \
  "$ym_ci_production/app/AutomaticUpdater.m" "$ym_ci_production/app/UpdateWorkspaceRecovery.m" \
  "$ym_ci_production/app/AppWorkspace.m" "$ym_ci_production/app/AppWorkspaceAccess.m" \
  "$ym_ci_production/app/AppWorkspaceView.m" \
  "$ym_ci_production/bridge/VDVirtualDisplay.m" "$ym_ci_production/bridge/YMDisplayTopology.m" \
  -framework AppKit -framework CoreGraphics -framework IOKit -framework Carbon -framework ApplicationServices -framework QuartzCore -framework ColorSync \
  -F "$ym_ci_sparkle" -framework Sparkle "-Wl,-rpath,$ym_ci_sparkle" \
  -o "$ym_ci_tmp/controller-tests"
"$ym_ci_tmp/controller-tests"
