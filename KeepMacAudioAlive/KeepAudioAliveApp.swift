import SwiftUI
import CoreAudio
import AppKit
import ServiceManagement
internal import Combine

// Never called from the audio render callback. Disk writes have their own queue,
// independent of both the main thread and potentially blocked CoreAudio calls.
nonisolated private enum DiagnosticLog {
    private static let writer = DispatchQueue(label: "KeepMacAudioAlive.diagnostics")
    private static let session = UUID().uuidString
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KeepMacAudioAlive", isDirectory: true)
    private static let file = directory.appendingPathComponent("lifecycle.log")
    private static let previous = directory.appendingPathComponent("lifecycle.previous.log")
    private static let limit = 2 * 1024 * 1024

    static func flush(completion: @escaping @Sendable () -> Void) {
        writer.async { completion() }
    }

    static func event(_ message: String) {
        // Capture the event time here, not when the asynchronous write executes.
        let date = Date()
        writer.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: date)) pid=\(ProcessInfo.processInfo.processIdentifier) session=\(session) \(message)\n"
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= limit {
                    if manager.fileExists(atPath: previous.path) {
                        try manager.removeItem(at: previous)
                    }
                    try manager.moveItem(at: file, to: previous)
                }
                if !manager.fileExists(atPath: file.path) {
                    guard manager.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                // Console fallback if file logging is unavailable.
                NSLog("KeepMacAudioAlive diagnostic write failed: %@; %@", "\(error)", line)
            }
        }
    }

    static func measure<T>(_ operation: String, _ body: () throws -> T) rethrows -> T {
        let id = UUID().uuidString
        let start = ContinuousClock.now
        event("BEGIN id=\(id) \(operation)")
        do {
            let result = try body()
            let resultText = (result as? OSStatus).map { " OSStatus=\($0)" } ?? ""
            event("END id=\(id) \(operation) elapsed=\(start.duration(to: .now))\(resultText)")
            return result
        } catch {
            event("END id=\(id) \(operation) elapsed=\(start.duration(to: .now)) error=\(error)")
            throw error
        }
    }
}

// UI state is main-thread confined. CoreAudio ownership lives on AudioController.queue.
@MainActor
final class AudioEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = true
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var status = "Connecting"
    @Published private(set) var isShuttingDown = false
    var hasFailure: Bool { status.localizedCaseInsensitiveContains("failed") }
    var offersStop: Bool { isEnabled && !hasFailure }
    @Published var selectedDeviceUID: String? {
        didSet {
            guard !isShuttingDown else { return }
            UserDefaults.standard.set(selectedDeviceUID, forKey: "LastSelectedDeviceUID")
            controller.select(selectedDeviceUID)
        }
    }

    nonisolated struct AudioDevice: Hashable, Identifiable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private let controller = AudioController()
    private var observers: [NSObjectProtocol] = []

    init() {
        DiagnosticLog.event("Application engine initialized")
        selectedDeviceUID = UserDefaults.standard.string(forKey: "LastSelectedDeviceUID")
        controller.report = { [weak self] devices, running, status in
            DispatchQueue.main.async {
                guard let self, !self.isShuttingDown else { return }
                self.devices = devices
                self.isRunning = running
                self.status = status
                DiagnosticLog.event("UI applied status=\(status) running=\(running)")
                if self.selectedDeviceUID == nil, let first = devices.first {
                    self.selectedDeviceUID = first.uid
                }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DiagnosticLog.event("NOTIFICATION willSleep received on main thread")
            self?.controller.setSleeping(true)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DiagnosticLog.event("NOTIFICATION didWake received on main thread")
            self?.controller.setSleeping(false)
        })
        controller.begin(uid: selectedDeviceUID)
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        controller.shutdown()
    }

    func start() {
        guard !isShuttingDown else { return }
        DiagnosticLog.event("USER Start")
        isEnabled = true
        controller.setEnabled(true)
    }

    func stop() {
        guard !isShuttingDown else { return }
        DiagnosticLog.event("USER Stop")
        isEnabled = false
        controller.setEnabled(false)
    }

    func shutdown(completion: @escaping @Sendable () -> Void) {
        isShuttingDown = true
        isEnabled = false
        isRunning = false
        status = "Quitting"
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        DiagnosticLog.event("Workspace observers removed; shutdown requested")
        controller.shutdown(completion: completion)
    }
}

// Pure health policy, with injected time for deterministic tests. A callback
// heartbeat establishes activity, not that physical speakers are silent.
nonisolated struct StreamHealth {
    enum Observation { case waiting, active, stalled }
    private var count: UInt64 = 0
    private var lastProgress: Double
    private var firstProgress: Double?
    private(set) var isActive = false

    init(now: Double) { lastProgress = now }

    mutating func observe(count: UInt64, now: Double) -> Observation {
        if count != self.count {
            self.count = count
            lastProgress = now
            if firstProgress == nil { firstProgress = now }
            isActive = true
            return .active
        }
        let limit = firstProgress == nil ? 5.0 : 3.0
        if now - lastProgress >= limit {
            isActive = false
            return .stalled
        }
        return isActive ? .active : .waiting
    }

    func isStable(now: Double) -> Bool {
        isActive && firstProgress.map { now - $0 >= 30 } == true
    }
}

nonisolated struct RecoveryBudget {
    private(set) var attempts = 0
    private let delays: [Double] = [0.5, 1, 2, 4, 8]
    mutating func reset() { attempts = 0 }
    mutating func nextDelay() -> Double? {
        guard attempts < delays.count else { return nil }
        defer { attempts += 1 }
        return delays[attempts]
    }
}

// All mutable lifecycle state below is owned by queue. The render callback never
// touches it. Nonisolated opts out of this project's default MainActor isolation.
nonisolated private final class AudioController: @unchecked Sendable {
    var report: (([AudioEngine.AudioDevice], Bool, String) -> Void)?
    private let queue = DispatchQueue(label: "KeepMacAudioAlive.lifecycle")
    private var listener: AudioObjectPropertyListenerBlock?
    private var uid: String?
    private var enabled = true
    private var sleeping = false
    private var closed = false
    private var devices: [AudioEngine.AudioDevice] = []
    private var stream: (device: AudioDeviceID, uid: String, proc: AudioDeviceIOProcID,
                         heartbeat: UnsafeMutableRawPointer)?
    private var health: StreamHealth?
    private var healthTimer: DispatchSourceTimer?
    private var teardownRequired = false
    private var generation = 0
    private var retry: DispatchWorkItem?
    private var recoveryBudget = RecoveryBudget()

    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    func begin(uid: String?) {
        queue.async { [self] in
            self.uid = uid
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.closed else { return }
                DiagnosticLog.event("Device-list notification executing on lifecycle queue")
                self.invalidateRetries()
                self.reconcile()
            }
            var address = Self.deviceListAddress
            let result = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, self.queue, listener)
            if result == noErr {
                self.listener = listener
            } else {
                self.log("Register device listener", result)
            }
            self.reconcile()
        }
    }

    func select(_ uid: String?) {
        queue.async {
            guard !self.closed else { return }
            self.uid = uid
            self.invalidateRetries()
            self.reconcile()
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async {
            guard !self.closed else { return }
            self.enabled = enabled
            self.invalidateRetries()
            self.reconcile()
        }
    }

    func setSleeping(_ sleeping: Bool) {
        let received = ContinuousClock.now
        DiagnosticLog.event("ENQUEUE sleeping=\(sleeping)")
        queue.async {
            DiagnosticLog.event("HANDLE sleeping=\(sleeping) queueWait=\(received.duration(to: .now))")
            defer { DiagnosticLog.event("HANDLED sleeping=\(sleeping) total=\(received.duration(to: .now))") }
            guard !self.closed else { return }
            self.sleeping = sleeping
            self.invalidateRetries()
            // Always discard pre-sleep ownership, even if willSleep was missed.
            self.publish(sleeping ? "Sleeping" : "Waking", running: false)
            guard self.tearDown() else { return }
            if !sleeping { self.reconcile() }
        }
    }

    func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        queue.async {
            guard !self.closed else {
                completion()
                return
            }
            DiagnosticLog.event("Shutdown executing on lifecycle queue")
            self.closed = true
            self.enabled = false
            self.invalidateRetries()
            if let listener = self.listener {
                var address = Self.deviceListAddress
                let result = DiagnosticLog.measure("Remove device listener") {
                    AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject), &address, self.queue, listener)
                }
                self.log("Remove device listener", result)
                self.listener = nil
            }
            let cleaned = self.tearDown()
            self.report = nil
            DiagnosticLog.event("Shutdown cleanup finished resourcesReleased=\(cleaned)")
            DiagnosticLog.flush(completion: completion)
        }
    }

    private func invalidateRetries() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation += 1
        retry?.cancel()
        retry = nil
        recoveryBudget.reset()
    }

    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        if teardownRequired {
            guard tearDown() else { return }
        }
        if sleeping || !enabled {
            publish(sleeping ? "Sleeping" : "Stopping", running: false)
            if tearDown() {
                publish(sleeping ? "Sleeping" : "Disabled", running: false)
            }
            return
        }
        do {
            devices = try DiagnosticLog.measure("Discover output devices") {
                try discoverDevices()
            }
            DiagnosticLog.event("Discovery complete outputs=\(devices.count) targetID=\(devices.first { $0.uid == uid }.map { String($0.id) } ?? "absent") generation=\(generation)")
        } catch {
            publish("Device discovery failed", running: false)
            guard tearDown() else { return }
            scheduleRetry()
            return
        }
        let target = devices.first { $0.uid == uid }
        if let stream, stream.device != target?.id || stream.uid != target?.uid {
            guard tearDown() else { return }
        }
        guard let target else {
            publish("Waiting for device", running: false)
            return
        }
        if stream != nil {
            checkHealth()
            return
        }
        publish("Connecting", running: false)
        guard let heartbeat = KMAHeartbeatCreate() else {
            DiagnosticLog.event("ERROR heartbeat allocation failed")
            scheduleRetry()
            return
        }
        var proc: AudioDeviceIOProcID?
        let created = DiagnosticLog.measure("AudioDeviceCreateIOProcID device=\(target.id)") {
            AudioDeviceCreateIOProcID(target.id, Self.render, heartbeat, &proc)
        }
        guard created == noErr, let proc else {
            log("Create IOProc", created)
            KMAHeartbeatDestroy(heartbeat)
            scheduleRetry()
            return
        }
        // Own the resource before starting, so every failure path can release it.
        stream = (target.id, target.uid, proc, heartbeat)
        let started = DiagnosticLog.measure("AudioDeviceStart device=\(target.id)") {
            AudioDeviceStart(target.id, proc)
        }
        guard started == noErr else {
            log("Start device", started)
            guard tearDown() else { return }
            scheduleRetry()
            return
        }
        // Do not reset retry budget merely because the start API succeeded.
        health = StreamHealth(now: ProcessInfo.processInfo.systemUptime)
        publish("Waiting for audio callbacks", running: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        healthTimer = timer
        timer.resume()
    }

    private func checkHealth() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard enabled, !sleeping, !closed, !teardownRequired,
              let stream, var health else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wasActive = health.isActive
        let result = health.observe(count: KMAHeartbeatRead(stream.heartbeat), now: now)
        self.health = health
        switch result {
        case .waiting:
            break
        case .active:
            if !wasActive { publish("Started", running: true) }
            if health.isStable(now: now) { recoveryBudget.reset() }
        case .stalled:
            publish("Audio callbacks stalled; recovering", running: false)
            guard tearDown() else { return }
            scheduleRetry()
        }
    }

    @discardableResult
    private func tearDown() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        healthTimer?.cancel()
        healthTimer = nil
        health = nil
        guard let stream else { return true }
        teardownRequired = true
        let stopped = DiagnosticLog.measure("AudioDeviceStop device=\(stream.device)") {
            AudioDeviceStop(stream.device, stream.proc)
        }
        log("Stop device", stopped)
        let destroyed = DiagnosticLog.measure("AudioDeviceDestroyIOProcID device=\(stream.device)") {
            AudioDeviceDestroyIOProcID(stream.device, stream.proc)
        }
        log("Destroy IOProc", destroyed)
        // A removed device no longer owns a usable IOProc. For other failures,
        // retain ownership and refuse to create a potentially duplicate stream.
        guard destroyed == noErr || destroyed == kAudioHardwareBadDeviceError else {
            publish("Stream cleanup failed. Click Start to retry.", running: false)
            return false
        }
        self.stream = nil
        // Destroy only after the IOProc has been removed, never while it could
        // still call into this memory. Failed cleanup retains both resources.
        KMAHeartbeatDestroy(stream.heartbeat)
        teardownRequired = false
        return true
    }

    private func scheduleRetry() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard enabled, !sleeping, !closed, retry == nil else { return }
        guard let delay = recoveryBudget.nextDelay() else {
            publish("Recovery failed. Click Start to retry.", running: false)
            return
        }
        let token = generation
        publish("Retrying in \(delay)s", running: false)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.closed else { return }
            DiagnosticLog.event("Retry executing generation=\(token) attempt=\(self.recoveryBudget.attempts)")
            self.retry = nil
            self.reconcile()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publish(_ status: String, running: Bool) {
        DiagnosticLog.event("STATE \(status) running=\(running) generation=\(generation)")
        report?(devices, running, status)
    }

    private func log(_ operation: String, _ status: OSStatus) {
        if status != noErr {
            DiagnosticLog.event("ERROR \(operation): OSStatus \(status)")
        }
    }

    private struct AudioError: Error {
        let status: OSStatus
    }

    private func discoverDevices() throws -> [AudioEngine.AudioDevice] {
        var address = Self.deviceListAddress
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else {
            log("Size device list", status)
            throw AudioError(status: status)
        }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        guard status == noErr else {
            log("Read device list", status)
            throw AudioError(status: status)
        }
        return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioEngine.AudioDevice(
                id: id, uid: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static let render: AudioDeviceIOProc = { _, _, _, _, output, _, context in
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        if let context { KMAHeartbeatTick(context) }
        return noErr
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    enum IconLocation: String, CaseIterable, Identifiable {
        case both = "Dock and menu bar"
        case dock = "Dock only"
        case menuBar = "Menu bar only"
        case neither = "Neither"
        var id: String { rawValue }
        var showsDock: Bool { self == .both || self == .dock }
        var showsMenuBar: Bool { self == .both || self == .menuBar }
    }
    @Published var iconLocation: IconLocation = {
        if let saved = UserDefaults.standard.string(forKey: "IconLocation"),
           let location = IconLocation(rawValue: saved) { return location }
        return UserDefaults.standard.bool(forKey: "ShowMenuBarIcon") ? .menuBar : .neither
    }() {
        didSet {
            UserDefaults.standard.set(iconLocation.rawValue, forKey: "IconLocation")
            menuVisibilityChanged?()
        }
    }
    @Published var showWindowOnLaunch = UserDefaults.standard.object(forKey: "ShowWindowOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWindowOnLaunch, forKey: "ShowWindowOnLaunch") }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var needsApproval = false
    @Published private(set) var updatingLogin = false
    @Published private(set) var loginError: String?
    var menuVisibilityChanged: (() -> Void)?

    init() { refreshLoginStatus() }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !updatingLogin else { return }
        updatingLogin = true
        loginError = nil
        Task { @MainActor in
            defer {
                refreshLoginStatus()
                updatingLogin = false
            }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                loginError = error.localizedDescription
                DiagnosticLog.event("Login item update failed: \(error)")
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var preferences: AppPreferences

    private var isAwaitingAutomaticStart: Bool {
        engine.offersStop && !engine.isRunning && !engine.isShuttingDown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if isAwaitingAutomaticStart {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundColor(engine.isRunning ? .green : .secondary)
                            .font(.title2)
                    }
                }
                .frame(width: 24, height: 24)
                Button(action: { engine.offersStop ? engine.stop() : engine.start() }) {
                    Text(engine.offersStop ? "Stop" : "Start")
                        .frame(width: 50)
                }
                Picker("Device", selection: $engine.selectedDeviceUID) {
                    if let uid = engine.selectedDeviceUID,
                       !engine.devices.contains(where: { $0.uid == uid }) {
                        Text("Selected device disconnected").tag(Optional(uid))
                    } else if engine.selectedDeviceUID == nil {
                        Text("No device selected").tag(String?.none)
                    }
                    ForEach(engine.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(engine.isRunning)
            }
            if engine.hasFailure {
                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .fixedSize()
        .disabled(engine.isShuttingDown)
    }
}

struct PreferencesView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at login", isOn: Binding(
                get: { preferences.launchAtLogin },
                set: { preferences.setLaunchAtLogin($0) }))
                .disabled(preferences.updatingLogin)
            Toggle("Show window on launch", isOn: $preferences.showWindowOnLaunch)
            Picker("Show icon in:", selection: $preferences.iconLocation) {
                ForEach(AppPreferences.IconLocation.allCases) { location in
                    Text(location.rawValue).tag(location)
                }
            }
            if preferences.iconLocation == .neither {
                Text("Open KeepMacAudioAlive from Finder or Spotlight to access its controls when it is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if preferences.needsApproval {
                Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = preferences.loginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// Testable one-shot gate: graceful completion and deadline must never both reply.
@MainActor
final class TerminationCoordinator {
    private var started = false
    private var finished = false
    private var deadline: DispatchWorkItem?

    func begin(
        cleanup: (@escaping @Sendable () -> Void) -> Void,
        schedule: (DispatchWorkItem) -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: $0)
        },
        reply: @escaping (Bool) -> Void
    ) {
        guard !started else { return }
        started = true
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(timedOut: true, reply: reply)
        }
        deadline = timeout
        schedule(timeout)
        cleanup { [weak self] in
            DispatchQueue.main.async {
                self?.finish(timedOut: false, reply: reply)
            }
        }
    }

    private func finish(timedOut: Bool, reply: (Bool) -> Void) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        reply(timedOut)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = AudioEngine()
    let preferences = AppPreferences()
    private let termination = TerminationCoordinator()
    private var controlWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.menuVisibilityChanged = { [weak self] in self?.applyIconPreferences() }
        engine.objectWillChange.sink { [weak self] _ in
            // objectWillChange precedes mutation; update from the resulting state.
            DispatchQueue.main.async { self?.updateStatusMenu() }
        }.store(in: &subscriptions)
        installApplicationMenu()
        applyIconPreferences()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.paramDescriptor(forKeyword: keyAEPropData)?
            .enumCodeValue == keyAELaunchedAsLogInItem
        DiagnosticLog.event("Application launched loginItem=\(loginLaunch)")
        if preferences.showWindowOnLaunch { showControls() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        preferences.refreshLoginStatus()
    }

    @objc private func showControls() {
        if controlWindow == nil {
            let content = ContentView()
                .environmentObject(engine)
                .environmentObject(preferences)
            let host = NSHostingController(rootView: content)
            host.sizingOptions = [.minSize, .maxSize, .preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Keep Mac Audio Alive"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            controlWindow = window
        }
        preferences.refreshLoginStatus()
        present(controlWindow)
    }

    private func updateStatusItem() {
        if preferences.iconLocation.showsMenuBar {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                statusItem?.button?.image = NSImage(
                    systemSymbolName: "waveform", accessibilityDescription: "Keep Mac Audio Alive")
            }
            updateStatusMenu()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func updateStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Open KeepMacAudioAlive", #selector(showControls))
        add(engine.offersStop ? "Stop" : "Start", #selector(toggleAudio))
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings))
        add("Quit KeepMacAudioAlive", #selector(quit))
        statusItem.menu = menu
        statusItem.button?.toolTip = "Keep Mac Audio Alive — \(engine.status)"
    }

    @objc private func toggleAudio() {
        engine.offersStop ? engine.stop() : engine.start()
    }

    @objc fileprivate func showSettings() {
        preferences.refreshLoginStatus()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: PreferencesView(preferences: preferences))
            host.sizingOptions = [.minSize, .maxSize, .preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "KeepMacAudioAlive Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    private func applyIconPreferences() {
        NSApp.setActivationPolicy(preferences.iconLocation.showsDock ? .regular : .accessory)
        updateStatusItem()
    }

    private func present(_ window: NSWindow?) {
        // Window presentation does not override the user's Dock preference.
        applyIconPreferences()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applyIconPreferences() }
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "KeepMacAudioAlive", action: nil, keyEquivalent: "")
        let app = NSMenu(title: "KeepMacAudioAlive")
        func add(_ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            app.addItem(item)
        }
        add("About KeepMacAudioAlive", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add("Settings…", #selector(showSettings), ",", target: self)
        add("Open KeepMacAudioAlive", #selector(showControls), target: self)
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        app.addItem(services)
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        add("Hide KeepMacAudioAlive", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add("Quit KeepMacAudioAlive", #selector(quit), "q", target: self)
        appItem.submenu = app
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        termination.begin(cleanup: { completion in
            engine.shutdown(completion: completion)
        }, reply: { timedOut in
            if timedOut {
                // Do not call CoreAudio concurrently to interrupt a stuck call.
                // Process exit is the fallback; it is not graceful cleanup.
                DiagnosticLog.event("QUIT deadline exceeded; exiting without confirmed cleanup")
                NSLog("KeepMacAudioAlive: cleanup exceeded five seconds; allowing process exit")
            }
            sender.reply(toApplicationShouldTerminate: true)
        })
        return .terminateLater
    }
}

#if !LIFECYCLE_TESTS
@main
enum AudioKeepAliveApp {
    @MainActor
    static func main() {
        // AppKit owns menus and windows; SwiftUI is only the hosted content.
        // This avoids competing SwiftUI scene-menu installation.
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
#endif
