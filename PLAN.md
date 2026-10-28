# KeepMacAudioAlive reliability and background-app plan

## Objective

Keep the Anker dock's analogue output quiet using continuous digital silence,
with reliable device lifecycle recovery and no permanent Dock or menu-bar icon.
Preserve the existing SoX workaround as a fallback; leave it stopped during
native-app testing so it cannot mask failures.

## Confirmed baseline

- Continuous digital silence suppresses the hum.
- Ordinary physical dock disconnection and reconnection recover automatically.
- Launching without the device, then connecting it, starts output automatically.
- Longer idle operation and resource usage appear acceptable.
- Rapid reconnect testing is deferred: attached drives must not be disturbed.
- Sleep causes the hum to return. Waking does not restore suppression, although
  the indicator remains green.
- After that failure, Stop clears the indicator. Start beachballs; the hum is
  suppressed again, but the indicator does not become green.

The cause of the beachball is not yet established. A process sample during the
hang would help distinguish a blocked CoreAudio operation from other causes.
Successful process survival or API startup is not proof of healthy playback.

## Scope and constraints

- Retain the direct CoreAudio IOProc and zero-filled output buffers.
- Continue targeting the selected device by UID, resolving its current numeric
  device ID on each connection.
- Do not change system volume or default audio output.
- Do not prevent system sleep. Silence while the Mac is actually asleep is not
  promised: software callbacks may stop during sleep. Automatic recovery after
  wake is the required outcome.
- Do not change or remove the existing SoX installation.
- Do not physically disconnect attached drives for testing without approval.

## 1. Sleep/wake lifecycle recovery — first implementation milestone

Review the current lifecycle paths and implement the minimum supporting
serialization from step 2 alongside this work.

- Separate user intent (`enabled`) from actual stream state.
- Serialize startup, teardown, device notifications, and sleep/wake events.
- On sleep, invalidate the current stream generation and attempt orderly
  teardown; do not assume the stream will survive sleep.
- On wake, enumerate devices again and resolve the selected UID to its current
  device ID. Never reuse a pre-sleep device ID without revalidation.
- If enabled and the device is available, create a fresh IOProc and start it.
- If absent, wait for device notifications rather than repeatedly opening it.
- Handle transient startup failures with capped backoff and a bounded retry
  budget. Reset the budget on relevant lifecycle events or explicit user retry.
- Clean up every partially initialized IOProc, including start failures.
- Reconcile stale stream teardown before attempting replacement startup.
- Ignore stale queued recovery work using a generation/token mechanism.
- Ensure there is at most one owned stream and one pending recovery attempt.
- Log lifecycle transitions and CoreAudio errors without logging in the audio
  callback.

Acceptance:

- With the dock attached, sleep and wake restores hum suppression automatically,
  without Stop/Start, terminal commands, or volume changes.
- Repeated sleep/wake cycles do not hang the UI or create duplicate streams.
- Disabled playback remains disabled across sleep/wake and device changes.
- Existing ordinary reconnection and absent-at-launch behaviour remain intact.

## 2. Keep lifecycle work off the UI thread

- Use one dedicated serial control queue for potentially blocking CoreAudio
  lifecycle operations and engine-owned mutable state.
- Publish UI state changes on the main thread.
- Keep the real-time audio callback independent of the control queue: no locks,
  blocking dispatch, allocation, or logging.
- Make Stop and Quit cleanup explicit, including listener/observer removal.
- Investigate blocking teardown/startup behaviour if the hang reproduces; merely
  moving a permanently blocked call off the UI thread is not sufficient recovery.

Acceptance: the window remains responsive during connection changes and recovery.

Implementation complete; user confirmed Stop → Start → Quit → reopen works:

- CoreAudio lifecycle operations remain on one serial queue, with queue
  preconditions on reconciliation, teardown, and retry management.
- AppKit's termination delegate now requests asynchronous shutdown explicitly,
  rather than relying on SwiftUI object deinitialization at process exit.
- Shutdown removes workspace observers, cancels pending retries, removes the
  device listener, tears down the stream, and drains pending diagnostic writes.
- UI controls and late status updates are disabled/ignored during shutdown.
- Stop reports Stopping until teardown finishes; cleanup failures remain visible.
- Quit has a five-second deadline. If a driver call or logging blocks, termination
  is allowed without claiming graceful cleanup. No concurrent CoreAudio call is
  used to attempt cancellation of the blocked call.
- A one-shot termination coordinator prevents duplicate replies from repeated
  Quit requests, timeout, or late cleanup completion.

Validation:

- `bash scripts/test-termination.sh` passes tests for graceful completion,
  deadline cancellation, repeated Quit, blocked cleanup, and late completion.
  These exercise termination coordination without opening an audio device.
- Debug Xcode build succeeds. No sleep/disconnection or application termination
  was triggered during implementation.
- Existing diagnostic log contains three sleep/wake cycles with lifecycle queue
  waits below 0.1 ms; longest completed measured audio call was about 50 ms.
  These logs do not reproduce or explain the earlier 20-second delay or Bluetooth
  freeze. Those remain open investigations if they recur.
- Device-specific cleanup failures, actual AppKit Quit integration, and UI
  responsiveness during physical transitions still require manual testing.

## 3. Stream activity and truthful status

- Record callback activity using a verified real-time-safe synchronization
  mechanism.
- Check activity outside the callback at a modest rate while playback is expected.
- Distinguish disabled, disconnected, connecting/retrying, streaming, and failed
  states rather than treating an API success as permanent health.
- Allow startup/wake grace periods; suspend stall detection during sleep and
  intentional teardown.
- Route detected stalls through the same serialized, bounded recovery path.
- Treat callback activity as evidence of buffer processing, not proof that the
  physical output is quiet.

Acceptance: stopped callbacks cannot leave the UI showing healthy playback
indefinitely, and recovery cannot create rapid retry loops or duplicate streams.

Implementation complete, pending physical stall/sleep/wake validation:

- Each IOProc owns a C11 atomic heartbeat counter. The callback increments it
  after zero-filling; no allocation, lock, logging, or dispatch occurs there.
- The C header requires always-lock-free unsigned long long atomics at compile
  time, retaining macOS 14.6 compatibility without Swift Synchronization APIs.
- The lifecycle queue checks progress once per second (200 ms timer leeway).
  Green is published only after observing callbacks.
- A five-second startup grace period and three-second no-progress threshold
  feed stalls through existing serialized teardown and bounded recovery.
- Retry budget resets after 30 seconds of observed healthy activity, not merely
  a successful AudioDeviceStart. Explicit user/lifecycle events still reset it.
- Monitoring stops on teardown, sleep, disable, and Quit. Callback memory is
  released after IOProc destruction; failed cleanup retains ownership.
- Policy and heartbeat tests pass for startup grace, stall detection, sustained
  health, replacement stream reset, counter wraparound, bounded retry budget,
  and atomic counter operations. Termination tests still pass; Debug build passes.
- Tests do not inject a real CoreAudio stall or establish physical hum suppression.
- A blocked lifecycle queue can also delay health checks. This monitor detects
  missing callbacks when the control queue is operational; it cannot interrupt
  a permanently blocked driver call. The existing Quit deadline remains in place.

## 4. Background operation without permanent icons

- Configure the application as an agent (`LSUIElement = YES`).
- Do not add a menu-bar item.
- Provide an on-demand settings/status window.
- Opening the app through Finder or Spotlight activates that window, including
  when the process is already running and the window was closed.
- Closing the window leaves enabled keepalive running.
- Provide explicit Enable/Disable and Quit controls.
- Preserve the selected device and define persistence of enabled state.
- Add or verify optional launch-at-login support; login launch should not require
  a permanently visible window.

Acceptance: no permanent Dock/menu-bar icon, accessible controls on reopening,
and predictable close-versus-quit behaviour.

Implemented for preview; manual UI/login validation pending:

- Generated app Info.plist sets LSUIElement. No Dock icon; menu-bar icon defaults
  off and is controlled by a persisted setting.
- AppDelegate owns one retained, reopenable controls window. Closing it does
  not terminate audio. Finder/Spotlight reopening activates it.
- Expandable Settings contains Launch at login and Show menu-bar icon toggles.
- Login registration uses SMAppService.mainApp, reads actual registration state,
  displays errors, and links to Login Items when approval is needed.
- Login-item launch detection suppresses the initial window. Ordinary launches
  show controls. Install a stable signed app in Applications before login testing.
- Optional menu exposes Open, Start/Stop, cancellation while waiting, Settings,
  and Quit. The controls window always includes an explicit Quit button.
- Existing termination and stream-health tests pass. Debug build passes and its
  generated Info.plist was verified to contain LSUIElement=true.
- No login item was registered/unregistered or app launched during implementation.
- Validate expansion/window resizing, icon toggling, close/reopen, Quit, and
  actual login startup on the installed build before marking acceptance complete.

### Revised presentation: separate Settings window

Supersedes the expandable-settings and always-hidden-login behaviour above:

- Separate Settings window, available through the standard application menu
  (Settings…, Command-comma) and optional status-item menu.
- Explicit application menu provides About, Settings, Open, Services, Hide,
  Show All, and Quit.
- “Show icon in:” offers Dock and menu bar, Dock only, Menu bar only, Neither.
  Switching Dock visibility changes activation policy; the prior menu-icon
  preference migrates when no new selection is stored.
- “Show window on launch” is an independent persisted checkbox, default on.
  It governs a new process launch, including login launch. Reopening an already
  running process always presents the controls.
- Launch at login remains a separate setting.
- Status-menu Quit is labelled “Quit KeepMacAudioAlive”.
- Multiple-output support remains a later change; audio behaviour is unchanged.
- Build and existing health/termination tests pass. Actual menu behaviour under
  both activation policies, settings resizing, login, and reopen still require
  manual validation.

### Menu and startup presentation correction

- Removed separate Cancel automatic start and routine status labels. Enabled
  startup/recovery shows a spinner and Stop; active callbacks show green and
  Stop; disabled or failed output offers Start. Device selection remains
  available whenever a stream is not running.
- Persistent failures retain concise visible errors; detailed states stay in logs.
- AppKit now owns application startup, menus, and windows; SwiftUI is hosted
  content only, eliminating competing scene-menu installation.
- Accessory activation policy does not provide a standard application menu.
  Opening controls/settings temporarily uses regular activation, including a
  Dock icon. After the last window closes, the selected background icon policy
  is restored. Settings explicitly describes this trade-off.
- Existing tests/build pass; on-device menu display and icon transitions still
  require visual validation. No app process was stopped or launched in this pass.

### User-selected icon policy (supersedes temporary Dock behaviour above)

- Window presentation no longer changes activation policy. Dock-selected modes
  use regular activation and the application menu; other modes stay accessory.
- Removed the installation guidance and temporary-Dock explanation from Settings.
- Removed the main-window Quit button and closing-window explanation.
- Settings/Quit remain in the application menu (Dock modes) and optional status
  menu. With Neither selected, neither menu is visibly available.

## Validation strategy

- Build after each milestone and review diagnostics.
- Add automated coverage for lifecycle reconciliation, partial-start cleanup,
  stale events, retry limits, and user intent where feasible through an abstracted
  CoreAudio boundary.
- Test sleep/wake first; coordinate with the user before triggering sleep.
- Test startup with the device absent and subsequent discovery when safe.
- Defer rapid unplug/replug and disconnect-during-initialization tests until the
  attached drives can be safely disconnected.
- Test the settings window, reopening, quitting, and login behaviour separately.
- Compare idle CPU/memory usage after reliability changes.
- Record physical hum suppression separately from API success and callback health.

## Implementation status

Step 1 is implemented, pending physical sleep/wake validation:

- Added workspace sleep/wake observers and fresh device enumeration on wake.
- Moved CoreAudio ownership and lifecycle operations to a dedicated serial queue.
- Separated enabled intent from running state; Stop remains effective across
  device notifications and sleep/wake.
- Added generation-checked startup retries at 0.5, 1, 2, 4, and 8 seconds.
  Device notifications, wake, selection changes, and user actions reset retries.
- Added partial-start cleanup and teardown-before-replacement ordering.
- Failed teardown retains resource ownership and blocks replacement creation;
  a subsequent lifecycle/user event can attempt cleanup again.
- Added status text and transition/error logging.
- The indicator still represents successful API startup, not callback health.
  Callback activity monitoring remains step 3.
- Background-agent presentation remains unchanged (step 4).

Validation completed:

- Debug build succeeded with code signing disabled.
- LSP diagnostics: none.
- `git diff --check` passed.
- Xcode emitted only the App Intents metadata warning (no AppIntents dependency).
- No app was launched, existing app replaced, system sleep triggered, or drives
  disconnected during implementation.
- Automated lifecycle/fault-injection tests have not yet been added.

Next manual validation:

1. Quit the existing app and ensure SoX is stopped.
2. Run the newly built app and confirm initial hum suppression.
3. With the dock attached, sleep/wake at a safe time. Hum during sleep is not
   considered a failure; after wake suppression should resume automatically.
4. Confirm the window remains responsive and status reaches Started.
5. Stop playback, sleep/wake, and confirm it remains Disabled.
6. Start again and confirm suppression returns without a beachball.
7. If it hangs or does not recover, capture lifecycle logs and a process sample
   before restarting. A permanently blocked CoreAudio call could still prevent
   progress on the serial control queue even though the UI remains responsive.

### Diagnostic follow-up

User testing reported Sleeping remaining visible for over 20 seconds, followed
by a several-second trackball freeze coincident with audio resumption. The
trackball initially works after waking the Mac. Cause remains unconfirmed.

- Added persistent, rotating lifecycle logging on a separate logging queue.
- Log notification receipt, queue wait, UI status application, and timed
  discovery/create/start/stop/destroy operations.
- Added `DIAGNOSTICS.md` and `scripts/capture-audio-sample.sh` for a user-triggered
  process sample during the delay. No sleep or sampling is triggered by the app.
- Recovery behaviour is unchanged in this diagnostic pass.

### Startup controls correction

- Start/Stop and device-picker availability now follow actual running state,
  not automatic-start intent. A grey/not-running stream offers Start and allows
  selecting a device without first clicking Stop.
- Automatic startup/reconnection remains enabled independently. Selecting a
  device while enabled reconciles immediately; Start explicitly retries.
- While enabled but not running, a separate Cancel automatic start action
  preserves the ability to disable pending startup/recovery.
- This corrects the confirmed UI lockout; it does not establish that a
  CoreAudio startup error occurred.
