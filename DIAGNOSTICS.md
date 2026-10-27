# Sleep/wake diagnostics

The diagnostic build records events without changing recovery behaviour.
It does not sample automatically, prevent sleep, or change Bluetooth settings.

## Reproduce

1. Quit the previous app and open the new build. Keep SoX stopped.
2. At a safe time, sleep and wake with the dock attached.
3. Note roughly when the trackball freezes and when the hum stops.
4. While status remains Sleeping (or during the freeze if possible), run:

   ```sh
   bash scripts/capture-audio-sample.sh
   ```

   Run from the repository directory. If multiple instances are running, pass
   the desired PID as an argument. Sampling takes five seconds and saves its
   report and available logs under `~/Downloads/KeepMacAudioAlive-diagnostics/`.
   Sampling adds diagnostic overhead; it should not be left running continuously.
   Alternatively use Activity Monitor → select the app → Sample Process.

5. After recovery completes, retain the current lifecycle log too: the script's
   snapshot might precede completion of the blocked operation.

## Log locations

The app writes relative to its effective home directory. This project enables
App Sandbox, so a sandboxed build normally writes:

```text
~/Library/Containers/com.github.openmac.KeepAudioAlive/Data/Library/Logs/KeepMacAudioAlive/lifecycle.log
```

If the development build runs without an active sandbox:

```text
~/Library/Logs/KeepMacAudioAlive/lifecycle.log
```

At 2 MiB the log rotates to `lifecycle.previous.log`, retaining one previous file.
Each entry includes wall-clock time, PID, and a session identifier. No audio
samples are recorded. Process samples can include local paths; review before
sharing publicly.

## Interpretation

- `NOTIFICATION ... received`: execution of the notification handler on the main
  thread, before dispatch to the lifecycle queue. This is not the physical wake
  time; OS notification delivery or main-thread scheduling may themselves lag.
- `ENQUEUE` / `HANDLE ... queueWait`: distinguishes receipt from queue execution.
- `BEGIN` / `END` with matching IDs: elapsed time for device discovery and each
  IOProc create, device start, stop, and IOProc destruction operation.
- An unmatched `BEGIN` during a stall identifies an operation still in progress
  (or interrupted by process exit), not necessarily its underlying cause.
- Elapsed durations use Swift's continuous clock, including time spent asleep.
  A stop operation begun before sleep and completed after wake therefore needs
  to be interpreted alongside the notification timestamps.
- `STATE` versus `UI applied`: distinguishes controller progress from UI updates.
- `Waiting for audio callbacks` means the start API succeeded but callbacks have
  not yet been observed. `Started` now means the heartbeat has advanced.
- Health checks run roughly once per second while a stream exists. There is a
  five-second startup grace period and a three-second no-progress threshold
  after callbacks begin. Timer scheduling/leeway can delay detection slightly.
- Stalls trigger teardown and bounded retries. Thirty seconds of observed
  healthy activity resets the retry budget; API startup alone does not.
- Callback activity does not establish that physical audio output is quiet.

Disk writes occur asynchronously on a separate queue. This allows notification
events and operation beginnings to reach the log even when the audio-control
queue is blocked. Abrupt termination can lose pending log entries. No logging
is performed inside the real-time audio callback.

A process sample may show where this application's threads are waiting. It
cannot by itself establish why Bluetooth froze or reveal all kernel/driver work.

## Stop and Quit verification

Quit now explicitly requests cleanup and allows up to five seconds before
permitting process exit if cleanup is blocked. The timeout is not a claim that
CoreAudio released resources successfully.

After starting the new build:

1. Click Stop. The window should stay responsive, the indicator should clear,
   and logs should show stop/destroy completion. Start should work again.
2. Quit using Command-Q or the application menu. Normal cleanup should finish
   quickly; logs should show listener removal and `Shutdown cleanup finished`.
3. Check `pgrep -fl KeepMacAudioAlive` to confirm process exit.
4. Reopen the app and confirm silence resumes.
5. If Quit takes five seconds, preserve the logs. The timeout is also sent to
   the system console because a blocked logging queue might not write its file.

Non-hardware termination-coordination checks:

```sh
bash scripts/test-termination.sh
```

Non-hardware callback-health and retry-budget checks:

```sh
bash scripts/test-stream-health.sh
```
