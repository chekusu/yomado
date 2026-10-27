---
name: yomado
description: "Prepare and manage yomado virtual work screens on macOS using existing computer-use tools. Use when an agent needs to create or name a work screen, move authorized app windows into it, verify visual access, or return those windows after a task."
---

# yomado

Let the agent prepare its own work screen; the user does not need to create it manually. Operate the installed yomado app through the agent's existing computer-use tools. This skill supplies the workflow, not a separate screenshot/input tool or management API.

## Before changing anything

- Confirm yomado is installed and the agent has tools for reading the actual native UI, screenshots and input. Use the available tool's documentation for its calls; do not invent an API. If the app is missing, use the official [download](https://yomado.app/) within the user's installation authority.
- Check that the capture tool supports selecting a non-primary display or its target window before creating a screen or moving apps. If it is known to capture only the primary display, stop before moving windows; a new screen will not fix that limitation.
- The macOS desktop must be logged in and unlocked. The user handles first-time macOS permission grants and any authentication. yomado needs window-control permission; the agent's tools need their own capture/input permissions.
- Identify the task's apps and windows from the user's request. Inspect the current screen layout, physical main display, virtual display names/IDs, bounds and scale, plus the original bounds of the windows that may move. Keep this recovery record local; do not publish window titles, screenshots or machine identifiers.
- Reuse a suitable screen belonging to this task when possible. A familiar name does not prove ownership: do not reuse, rename or close another task's screen without authority. Coordinate with any existing desktop owner before GUI operations.
- Virtual screens share the login session, focus, keyboard and pointer. They do not provide independent agent input. Follow **Share the mouse and keyboard** below before any input.

## Prepare the screen

1. Open yomado's control panel from its menu-bar item or by opening the installed app. Opening an existing instance brings back its panel; do not quit or restart it to find the panel.
2. Inspect the live UI. In v0.3.3, the menu-bar accessibility label is `yomado · 夜窗` and its panel item is `打开控制面板`. Labels may change in later versions; use current observations, not fixed coordinates.
3. If the live panel has `＋ 新建屏幕`, open it, enter a task-owned name such as `Codex · Blender`, choose resolution and HiDPI, then select `创建并启动`. For a saved task-owned screen, use `启动` in the `未启动的虚拟屏` section; use `编辑` to change its stopped configuration without starting it. Running screens can be renamed from `…` → `重命名…`. Older releases may still use the header `+` menu and saved-screen submenus: follow the controls actually observed, never fixed coordinates or assumed labels.
4. Record the new screen's actual ID/bounds/scale. A renamed running screen can retain its old name in macOS until restarted; do not restart merely to synchronize the name.
5. Compare the display arrangement and main display with the checkpoint before moving apps. Adding or removing displays can rearrange the desktop in released versions. If an existing screen moved, stop and report the discrepancy; do not continue moving user windows or silently change the main display. Resolve layout only within the user's authority.

Keep physical outputs enabled and a physical display as main during ordinary setup. Do not change power, lock, login or display settings just because the task needs a work screen. Resolution/HiDPI controls apply to a stopped screen; do not stop an occupied screen to change them.

## Move only the task's windows

Choose the narrowest supported operation after inspecting its scope:

| Control | Windows it selects |
| --- | --- |
| Drag an app icon from one screen tile to another | That app's ordinary windows on the source screen |
| Target screen **+** → `App · 实体屏` | That app's ordinary windows across **all physical screens** |
| Target screen **+** → `App · <virtual screen>` | That app's ordinary windows on the named virtual source |
| Drop a running `.app` bundle from Finder | That app's ordinary windows across screens |

An icon is an app/window group, not a single-window or process selector. If the selected group includes personal or other-task windows, do not use that group operation. Use a verified per-window move supported by the existing computer-use tool, if available and authorized; otherwise obtain a narrower selection from the user. Do not collect all windows to make capture easier.

Drag into the target screen tile, or use its **+** chooser only when the chooser's full scope is authorized. Check fresh window bounds and the screen's app inventory after the move. An icon/count describes detected visible windows, not GPU activity or proof of agent access. Some apps refuse Accessibility positioning.

If the header shows a lock icon, window movement needs permission. The icon opens the relevant macOS settings page; let the user grant access. Opening settings is not authorization. Do not reset permissions or keep retrying the same failed move.

## Verify before working

1. Select the actual target display/window in the agent's capture tool. The tool may list the virtual screen under a generic name (such as `display 7`) rather than its yomado name; match it by display ID or bounds. Acquire a fresh target-app screenshot and current window bounds, pixel dimensions and scale; discard pre-move coordinates. A correct, fresh target screenshot is required before any test input.
2. Perform one authorized, reversible operation in the real target app, such as opening and dismissing a menu or changing and restoring a view. Confirm the change in a new screenshot before claiming visual operation works.
3. If targeting fails only after the move, stop input and safely return only this task's moved windows using their checkpoint. If recovery cannot be verified, leave the screen running and report the pending recovery. Do not make the virtual screen primary or move unrelated windows as a workaround.
4. Stop on blank/stale capture, wrong-window input, unexpected layout changes, login/security prompts or rejected movement. Use the same scoped recovery path for failed capture/input. On a login/security prompt, return only the moved app's windows to their recorded physical display if safe, then let the user handle the prompt. Do not repeatedly attempt login or dismiss security checks.

Screen creation, an accessibility tree, a running process or a synthetic preview is not evidence of target-app visual input. Keep claims specific to the app and operation actually observed. This skill does not establish locked-session operation or input isolation.

## Share the mouse and keyboard

The user may be working on the physical screens while the agent works on the virtual one. Choose input in this order:

1. **Background input (default).** Use the tool's methods that leave the user's pointer, keyboard focus and frontmost app untouched: Accessibility actions on specific elements (press, set value, set window position), and events delivered to the target process only. Verify with a fresh capture that the pointer did not move and the frontmost app did not change. Browsers, Electron and ordinary Mac apps usually work this way.
   A background tool can report an event as delivered while the app ignores it. Confirm every effect in a fresh capture or by reading the app's state; do not trust the delivery result alone. If the app has a scripting interface or a dedicated MCP (for example Blender's Python API), prefer that over pointer input.
   Do not open modal tools from the background. A background menu press that opens a modal window can leave the app unresponsive to Accessibility until it is brought forward or restarted (seen with Marvelous Designer's Plugins ▸ Python Editor). Open such tools only under a lease, in the foreground.
2. **Borrowed real input (only when background input cannot work).** 3D viewports and other canvas apps (for example Blender or Marvelous Designer viewports, games) often accept only real pointer and keyboard events. Check first that the tool can produce the input the app needs; Marvelous Designer, for example, orbits with a right-drag, which some tools cannot send. Before posting any such event, ask the user through yomado and wait for the answer:

   ```sh
   /path/to/Yomado.app/Contents/MacOS/Yomado --input request --agent "Codex" --reason "Orbit the Blender viewport" --seconds 120
   ```

   It prints one JSON line. Continue only on `"status":"granted"` (exit 0) and keep its `leaseID`. `denied`, `timeout` and `busy` (exit 2) mean do not take the pointer: stop and report, or keep to background input. `not-running` (exit 3) means yomado is not running or is older than this feature; do not take the pointer without asking the user another way.

   While the lease is active, yomado shows "Agent 正在使用你的鼠标键盘" with a Stop button at the top-right of the main screen. Before each batch of real input, check the lease:

   ```sh
   Yomado --input status --lease <leaseID>
   ```

   Continue only while it reports `"status":"active"`. `ended` with reason `stopped` means the user took the controls back: stop at once and do not ask again for this step without the user. When done, release it so yomado hides the notice and puts the user's pointer and front app back:

   ```sh
   Yomado --input release --lease <leaseID>
   ```

   Get every other approval the step needs first (for example the agent tool's own full-control or app-access prompts), then request the lease, so the lease time is not spent waiting on them. If the agent's tool hides other apps while it has full control, include yomado in its allowed apps so the prompt and notice stay visible. Run each `status` check on its own and wait for it before the next input batch.

   Request only the time the step needs (10–600 seconds), with room for capture and verification. A lease is permission to post input, not a guarantee the user is away; keep batches short and re-capture before each one. Never borrow real input without a granted lease, and never ask repeatedly after a denial.

## Return windows and finish

- Save task work as authorized before recovery. Return only the windows moved for this task. Inspect scope again if new windows appeared during the task.
- For a yomado-managed app, its icon on a virtual screen offers a return menu (right-click, or focus and press Space/Return where supported). Opening that menu does not itself restore the app. Select `返回原显示器`; without a stored checkpoint the label is `移回实体屏`.
- Ordinary app checkpoints are held in memory for the current yomado run and survive transfers between virtual screens. Returning to the recorded original physical screen restores its placement. A different destination, or no checkpoint, centers windows instead; use the private pre-move record to verify/recover exact placement when supported. Do not promise exact restoration without evidence.
- WeChat has additional recovery behavior: a pending checkpoint takes priority and returns to its original physical display. Return it there before a further virtual-screen transfer. Restoring its window cannot restore an expired login.
- Confirm restored bounds. Close a task-created screen only after its work is saved, its windows are accounted for, and no other task needs it. Use that screen's **…** → `关闭这块虚拟屏`; never use **Quit yomado** to close one screen. Verify the remaining layout afterwards. If recovery is refused or uncertain, leave the screen running and report it.
- Report the screen used, apps moved, screenshot/input checks actually completed, and whether the screen remains available or was closed. State any unresolved recovery or targeting limitation.

## Current command-line boundary

The public v0.3.3 app has `--diagnose` for local capability/display diagnostics. Versions that include the input lease also accept `--input request|status|release` as described above. There is no public create/move/restore CLI or management RPC; do not invent or probe such commands, including `--help` (unknown arguments open the normal app UI). Do not add `--include-device-identifiers` to shared diagnostics. `--preview-ui` renders sample data, while `--self-test` and `--watchdog-test` are developer tests that can change displays; none is a normal work-screen setup command.
