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
- `Started` still means the start API succeeded, not verified callback activity
  or physical audio output. Callback-health monitoring is a separate milestone.

Disk writes occur asynchronously on a separate queue. This allows notification
events and operation beginnings to reach the log even when the audio-control
queue is blocked. Abrupt termination can lose pending log entries. No logging
is performed inside the real-time audio callback.

A process sample may show where this application's threads are waiting. It
cannot by itself establish why Bluetooth froze or reveal all kernel/driver work.
