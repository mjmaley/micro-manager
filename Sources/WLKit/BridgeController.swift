import Foundation
import SwiftUI
import IOKit
import IOKit.hid
import OSLog

/// Drives the pad from Herdr agent status: each agent gets its own key, lit
/// by herdr-core's reported status and the Herdr app's read tracking, and the
/// underglow follows the agent in the app's focused pane. The menu-bar icon
/// retains the worst-state aggregate.
///
/// Agents are re-read on a short poll and whenever the frontmost app changes;
/// each read is the complete truth, so a missed change never leaves the pad
/// showing something stale for longer than one poll.
@MainActor
public final class BridgeController: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var deviceConnected = false
    @Published public private(set) var keymapReady = false
    @Published public private(set) var permissionDenied = false
    @Published public private(set) var secureInputPaused = false
    @Published public private(set) var secureInputApplication: String?
    @Published public private(set) var hardwareInputReady = false
    @Published public private(set) var lastHIDError: String?
    @Published public private(set) var deviceName = "—"
    @Published public private(set) var firmware = "—"
    @Published public private(set) var battery: String?
    @Published public private(set) var agents: [HerdrAgent] = []
    /// The six-agent bank currently shown on the pad. Bank zero is the first
    /// six agents in Herdr's live ordering.
    @Published public private(set) var agentPage = 0
    @Published public private(set) var keyColors: [Int: Color] = [:]
    @Published public private(set) var keyEffects: [Int: OAI.Effect] = [:]
    @Published public private(set) var aggregateState: String?
    @Published public private(set) var lastError: String?
    /// Another process is talking to the same pad. A shared HID open means we
    /// receive its replies too, so a response id we never issued is a reliable
    /// tell.
    @Published public private(set) var contendingClient = false
    /// Whether the GitButler stack is on screen. Only the key light cares —
    /// the panel itself lives in the app layer.
    @Published public private(set) var stackPanelOpen = false
    /// Same for the land window.
    @Published public private(set) var landPanelOpen = false
    /// Whether an OpenWhispr take is open, for the voice key's light.
    @Published public private(set) var voiceActive = false
    /// Device-specific geometry and the layer reserved for Herdr. Codex Micro
    /// keeps its native integration on Layer 1 and defaults Herdr to Layer 2.
    @Published public private(set) var padConfiguration = Pad.creatorMicro2
    /// `device.status.layer_index`, which firmware 0.6.2 reports one-based.
    @Published public private(set) var activeLayerNumber: Int?

    public var herdrLayerNumber: Int { padConfiguration.herdrLayerNumber }
    public var isHerdrLayerActive: Bool { activeLayerNumber == herdrLayerNumber }
    public var agentPageSize: Int { max(1, padConfiguration.agentKeyIDs.count) }
    public var agentPageCount: Int {
        max(1, (agents.count + agentPageSize - 1) / agentPageSize)
    }
    public var visibleAgents: [HerdrAgent] {
        let start = min(agentPage * agentPageSize, agents.count)
        return Array(agents.dropFirst(start).prefix(agentPageSize))
    }
    public var agentPageLabel: String? {
        guard !agents.isEmpty else { return nil }
        let start = agentPage * agentPageSize
        let end = min(start + agentPageSize, agents.count)
        return "\(start + 1)–\(end) of \(agents.count)"
    }

    public var config: BridgeConfig
    /// Text macros for the spare keys, reloaded on every bridge start so a
    /// config edit only needs an off/on toggle, not a relaunch.
    public private(set) var keyBindings = KeyBindings.load()

    /// Called when the stack key is pressed. The bridge owns the key, the app
    /// owns the window, so this is where the two meet.
    public var onStackKey: (() -> Void)?
    /// Called when the land key is pressed; same split as `onStackKey`.
    public var onLandKey: (() -> Void)?
    /// Row-3 Pi controls, matching the FAST/APPR/REJ/SPLIT keycaps.
    public var onFastKey: (() -> Void)?
    public var onApproveKey: (() -> Void)?
    public var onRejectKey: (() -> Void)?
    public var onSplitKey: (() -> Void)?
    /// Called when either half of the wide voice key is pressed.
    public var onVoiceKey: (() -> Void)?
    /// Called per dial detent: +1 clockwise, -1 counter-clockwise.
    public var onDial: ((Int) -> Void)?
    /// Called when the dial is pressed; Pi uses it to confirm a selector.
    public var onDialClick: (() -> Void)?
    /// Called when the joystick enters a cardinal sector.
    public var onJoystick: ((Pad.JoystickDirection) -> Void)?
    /// Consulted before any key does its normal job. Returning true consumes
    /// the press — this is how a pending land confirmation turns every other
    /// key into "cancel" without those keys also doing their usual work.
    public var onKeyIntercept: ((Int) -> Bool)?
    /// Successful, current Herdr snapshots, independent of HID connectivity.
    public var onAgentSnapshot: (([HerdrAgent]) -> Void)?
    public var onAgentObservationReset: (() -> Void)?

    // MARK: - Internals

    private var device = WLDevice()
    /// Non-nil while the bridge is driving a virtual pad instead of hardware.
    @Published public private(set) var emulator: PadEmulator?
    private var pollTask: Task<Void, Never>?
    private var layerMonitorTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var secureInputTask: Task<Void, Never>?
    private var inputGate = HardwareInputGate()
    private var openingDevice = false
    private var recoveryReadOnly = false
    private var reopenSequence: UInt64 = 0
    private var ownerCheckAt = Date.distantPast
    private let inputLogger = Logger(subsystem: "cc.worklouder.micromanager", category: "HardwareInput")
    private var snapshotSequence = 0
    private var lastFingerprint: String?
    private var layerLighting = LayerLightingState()
    private var lightingCache = PadLightingCache()
    private var pendingLighting: PadLightingFrame?
    private var lightingTask: Task<Void, Never>?
    private var lightingWorkerGeneration: UInt64 = 0
    private var lastInputAt: TimeInterval = -.infinity
    private var terminalActivationObserver: NSObjectProtocol?
    private var lastPublishedFingerprint: String?
    private var issuedIDs = Set<Int>()
    private var statusFailureCount = 0
    /// The submit switch can occasionally replay a press while the shared HID
    /// transport is reconnecting. Keep its debounce isolated from approvals
    /// and other controls, where every deliberate press must be delivered.
    private var lastSubmitPressAt: TimeInterval?
    /// HID handles can survive display sleep while losing permission to send
    /// reports. Track suspension explicitly so wake always opens a fresh handle.
    private var suspendedForSystemInactivity = false
    private var warnedPermission = false
    /// Codex Micro's single wide key drives both matrix switches. Keep their
    /// down-state as one gesture so AG10+AG11 toggles voice exactly once.
    private var wideKeysDown = Set<Int>()

    public init(config: BridgeConfig = BridgeConfig()) {
        self.config = config
        wire(device)
    }

    /// Swap the hardware for a virtual pad, or back. The device is rebuilt
    /// either way, so the bridge reconnects from scratch rather than trying to
    /// carry state across a transport it no longer has.
    public func useEmulator(_ on: Bool) async {
        guard on != (emulator != nil) else { return }
        let wasRunning = isRunning
        if wasRunning { await stop() }
        let pad = on ? PadEmulator() : nil
        emulator = pad
        device = WLDevice(emulator: pad)
        wire(device)
        if wasRunning { await start() }
    }

    private func wire(_ device: WLDevice) {
        device.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.deviceConnected = false
            self.inputGate.invalidate()
            self.hardwareInputReady = false
            self.activeLayerNumber = nil
            self.layerLighting.reset()
            self.resetLightingOutput()
            self.lastFingerprint = nil
            if self.isRunning { self.scheduleReopen() }
        }
        device.onWriteError = { [weak self] method, message in
            guard let self else { return }
            self.lastHIDError = message
            self.inputLogger.error("HID write failed method=\(method, privacy: .public) error=\(message, privacy: .public)")
            guard !self.refreshSecureInput() else { return }
            self.markDeviceUnavailable(message)
        }
        device.onSecureInputBlocked = { [weak self] in _ = self?.refreshSecureInput() }
        device.onTX = { [weak self] _, _, id in
            self?.issuedIDs.insert(id)
        }
        device.onResponse = { [weak self] id, method, _, _ in
            guard let self else { return }
            if self.issuedIDs.remove(id) == nil {
                self.contendingClient = true
                // Codex also queries battery/status. Those replies do not
                // justify a full repaint after every focus event.
                if self.lightingCache.invalidate(method: method) {
                    self.lastFingerprint = nil
                }
            }
        }
        device.onNotification = { [weak self] method, params in
            guard let self, !self.refreshSecureInput(), self.hardwareInputReady else { return }
            if method == OAI.notifyHID || method == OAI.notifyJoystick {
                self.lastInputAt = ProcessInfo.processInfo.systemUptime
            }
            guard method == OAI.notifyHID,
                  let dict = params as? [String: Any],
                  let action = dict["act"] as? Int,
                  let index = OAI.agIndex(dict["k"] as? String)
            else { return }
            let inputGeneration = self.inputGate.generation

            if Pad.voiceKeyIDs.contains(index) {
                if action == 0 {
                    self.wideKeysDown.remove(index)
                    return
                }
                guard action == 1 else { return }
                let firstHalf = self.wideKeysDown.isEmpty
                self.wideKeysDown.insert(index)
                guard firstHalf else { return }
            } else {
                guard action == 1 else { return }   // press, not release
            }

            if index == Pad.submitKeyID {
                let now = ProcessInfo.processInfo.systemUptime
                if let previous = self.lastSubmitPressAt, now - previous < 0.18 { return }
                self.lastSubmitPressAt = now
            }

            // On Codex Micro, the verified Layer 1 map uses ACT06...ACT12 and
            // proprietary encoder events. Receiving AG06 or above therefore
            // proves this event came from Herdr's Layer 2; dispatch it directly
            // instead of risking an approval press on an unnecessary status
            // round-trip. AG00...AG05 exist on both layers and still require a
            // fresh layer check.
            if self.padConfiguration.isCodexMicro, self.keymapReady,
               index >= Pad.fastKeyID {
                self.handleKeyPress(index)
                return
            }

            Task { [weak self] in
                guard let self,
                      await self.updateDeviceStatus() != nil,
                      !self.refreshSecureInput(), self.inputGate.accepts(inputGeneration),
                      self.isHerdrLayerActive
                else { return }
                self.handleKeyPress(index)
            }
        }
    }

    // MARK: - Lifecycle

    public func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        contendingClient = false
        wideKeysDown.removeAll()
        lastSubmitPressAt = nil
        keyBindings = KeyBindings.load()
        recoveryReadOnly = false
        inputGate.invalidate()
        hardwareInputReady = false
        startSecureInputMonitor()

        await openDevice()
        startFocusObservation()
        await refresh(forcePaint: true)
        startLayerMonitor()

        startPoll()
    }

    public func stop() async {
        isRunning = false
        secureInputTask?.cancel(); secureInputTask = nil
        inputGate.invalidate()
        hardwareInputReady = false
        secureInputPaused = false
        secureInputApplication = nil
        layerLighting.reset()
        resetLightingOutput()
        stopFocusObservation()
        snapshotSequence += 1
        onAgentObservationReset?()
        pollTask?.cancel(); pollTask = nil
        layerMonitorTask?.cancel(); layerMonitorTask = nil
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        wakeTask?.cancel(); wakeTask = nil
        suspendedForSystemInactivity = false
        statusFailureCount = 0
        wideKeysDown.removeAll()
        lastSubmitPressAt = nil
        issuedIDs.removeAll()
        lastFingerprint = nil
        lastPublishedFingerprint = nil

        // Switching off clears the lights but deliberately leaves the keymap
        // alone: rebinding is a flash write, and the keys light instantly on
        // the way back in if the bindings are still there.
        if device.isConnected {
            // Never blank Codex's Layer 1 while shutting down from another
            // layer. If Herdr owns the visible layer, leave it clean.
            if isHerdrLayerActive { await allLightsOff() }
            device.disconnect(reason: nil)
        }
        deviceConnected = false
        activeLayerNumber = nil
        keyColors = [:]
        keyEffects = [:]
        aggregateState = nil
        agents = []
        agentPage = 0
    }

    // MARK: - Device

    /// Blank Herdr's layer and release the HID handle before the display, login
    /// session, or machine sleeps. The pad remains USB-powered and otherwise
    /// keeps its last firmware lighting indefinitely.
    public func prepareForSystemInactivity() {
        guard isRunning, !suspendedForSystemInactivity else { return }
        suspendedForSystemInactivity = true
        inputGate.invalidate()
        hardwareInputReady = false
        secureInputTask?.cancel(); secureInputTask = nil
        layerLighting.reset()
        resetLightingOutput()
        stopFocusObservation()
        snapshotSequence += 1
        onAgentObservationReset?()

        pollTask?.cancel(); pollTask = nil
        layerMonitorTask?.cancel(); layerMonitorTask = nil
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        wakeTask?.cancel(); wakeTask = nil
        wideKeysDown.removeAll()
        lastSubmitPressAt = nil

        // Do not await replies: sleep may follow immediately. SetReport itself
        // is synchronous, so both messages reach the device before we close.
        if device.isConnected, isHerdrLayerActive { allLightsOffImmediately() }
        device.disconnect(reason: nil)
        issuedIDs.removeAll()
        deviceConnected = false
        activeLayerNumber = nil
        lastFingerprint = nil
    }

    /// Reopen from scratch after screen/session wake. A short delay lets macOS
    /// restore the HID service and Input Monitoring authorization first.
    public func resumeAfterSystemInactivity() {
        guard isRunning, suspendedForSystemInactivity else { return }
        suspendedForSystemInactivity = false
        startSecureInputMonitor()
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            do {
                // Both clients rebuild their HID transports on wake. Giving
                // Codex a short head start avoids interleaving two initial
                // multi-report lighting writes on firmware 0.6.2.
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard let self, self.isRunning, !self.suspendedForSystemInactivity else { return }
            self.wakeTask = nil
            await self.openDevice()
            self.startFocusObservation()
            self.startLayerMonitor()
            self.startPoll()
            if self.deviceConnected { await self.forceRepaint() }
        }
    }

    private func startPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.config.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                // Poll Herdr as a liveness backstop. Shared-client responses
                // invalidate the lighting fingerprint, so this refresh also
                // repairs a real overwrite without unconditional HID writes.
                await self.refresh(updateLayer: false)
            }
        }
    }

    private func openDevice() async {
        guard isRunning, !suspendedForSystemInactivity, !refreshSecureInput() else { return }
        guard !openingDevice else { scheduleReopen(); return }
        openingDevice = true
        defer { openingDevice = false }
        let inputGeneration = inputGate.generation
        hardwareInputReady = false
        inputLogger.info("Hardware validation starting; read-only recovery=\(self.recoveryReadOnly)")
        // Ask for Input Monitoring explicitly. hidapi-style opens just fail
        // with a privilege violation without ever raising the prompt, which
        // reads as a bug rather than a permission.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        do {
            try device.connect()
            deviceConnected = true
            permissionDenied = false
            warnedPermission = false
            statusFailureCount = 0
            deviceName = device.info?.product ?? "Work Louder device"
            if let info = device.info {
                var detected = Pad.configuration(productID: info.productID, product: info.product)
                if let value = ProcessInfo.processInfo.environment["WL_HERDR_LAYER"],
                   let number = Int(value), number > 0 {
                    detected = detected.withHerdrLayer(number: number)
                }
                padConfiguration = detected
            }
            lastError = nil
        } catch {
            deviceConnected = false
            let message = error.localizedDescription
            inputLogger.error("Hardware open failed: \(message, privacy: .public)")
            if message.contains("0xE00002C1") || message.contains("Input Monitoring") {
                permissionDenied = true
                if !warnedPermission { warnedPermission = true; lastError = message }
            } else {
                lastError = message
            }
            scheduleReopen()
            return
        }

        if let version = try? await device.callAsync("sys.version"),
           let dict = version as? [String: Any],
           let text = dict["version"] as? String {
            firmware = text
        }
        guard deviceConnected, inputGeneration == inputGate.generation, !refreshSecureInput() else { return }
        guard await updateDeviceStatus() != nil else {
            if !refreshSecureInput() { markDeviceUnavailable("Could not validate the active device layer.") }
            return
        }
        guard deviceConnected, inputGeneration == inputGate.generation, !refreshSecureInput() else { return }
        await ensureKeymap(readOnly: recoveryReadOnly)
        guard deviceConnected, !refreshSecureInput(), activeLayerNumber != nil, keymapReady,
              inputGate.validated(inputGeneration) else {
            scheduleReopen()
            return
        }
        hardwareInputReady = true
        inputLogger.info("Hardware input ready; fresh layer/keymap validated layer=\(self.activeLayerNumber ?? -1)")
    }

    /// Per-key lighting only works on keys bound to `KV_OAI_AG*` on the Herdr
    /// layer, and nothing reports a mismatch — `v.oai.thstatus` answers
    /// `{"ok":1}` for a key it cannot light. So check rather than assume.
    private func ensureKeymap(readOnly: Bool = false) async {
        let layerIndex = padConfiguration.herdrLayerIndex
        do {
            if config.manageKeymap && !readOnly {
                _ = try await KeymapManager.apply(device, layerIndex: layerIndex)
                keymapReady = true
            } else {
                let cfg = try await KeymapManager.read(device)
                keymapReady = KeymapManager.isAgentKeymapApplied(cfg, layerIndex: layerIndex)
                if !keymapReady {
                    lastError = "Layer \(herdrLayerNumber) is not bound to the Herdr AG keymap, so per-key colours will do nothing."
                }
            }
        } catch {
            keymapReady = false
            lastError = "Keymap: \(error.localizedDescription)"
            inputLogger.error("Hardware keymap validation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Refreshes battery and active-layer state. Returns whether the layer
    /// changed, or nil when it could not obtain a fresh status. The firmware
    /// reports `layer_index` one-based on the tested Codex Micro firmware.
    @discardableResult
    private func updateDeviceStatus() async -> Bool? {
        guard deviceConnected, !suspendedForSystemInactivity, !refreshSecureInput() else { return nil }
        let observationGeneration = layerLighting.generation

        let status: [String: Any]
        do {
            guard let response = try await device.callAsync("device.status") as? [String: Any]
            else { throw WLDevice.Failure.rpc("device.status", "unexpected response") }
            status = response
        } catch {
            guard observationGeneration == layerLighting.generation,
                  deviceConnected, !suspendedForSystemInactivity else { return nil }
            statusFailureCount += 1
            // A transient shared-client collision can lose a response. Three
            // consecutive failures mean the handle is no longer trustworthy.
            if statusFailureCount >= 3 { markDeviceUnavailable(error.localizedDescription) }
            return nil
        }

        // A concurrent status request, disconnect, or sleep can make this
        // response stale. Do not turn an old observation into a new handoff.
        guard observationGeneration == layerLighting.generation,
              deviceConnected, !suspendedForSystemInactivity else { return nil }
        statusFailureCount = 0

        if let percent = status["battery"] as? Int {
            let charging = (status["is_charging"] as? Bool) == true
            let value = "\(percent)%\(charging ? " ⚡" : "")"
            if battery != value { battery = value }
        }
        let previous = activeLayerNumber
        if let layer = status["layer_index"] as? Int, activeLayerNumber != layer {
            activeLayerNumber = layer
        }
        let changed = previous != activeLayerNumber
        let handoff = layerLighting.observe(activeLayerNumber, managedLayer: herdrLayerNumber)
        if changed {
            lastFingerprint = nil
            resetLightingOutput()
        }
        if let handoff, padConfiguration.isCodexMicro {
            await clearLightingForLayerHandoff(token: handoff)
        }
        return changed
    }

    /// Layer changes have no known notification, so watch the cheap status RPC.
    /// Input events still confirm the layer synchronously before dispatch.
    private func startLayerMonitor() {
        layerMonitorTask?.cancel()
        layerMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_250_000_000)
                if Task.isCancelled || !self.isRunning { break }
                let changed = await self.updateDeviceStatus()
                if changed == true && self.isHerdrLayerActive {
                    await self.refresh(forcePaint: true, updateLayer: false)
                }
            }
        }
    }

    private func markDeviceUnavailable(_ message: String) {
        guard !suspendedForSystemInactivity, deviceConnected || device.isConnected else { return }
        deviceConnected = false
        inputGate.invalidate()
        hardwareInputReady = false
        activeLayerNumber = nil
        layerLighting.reset()
        resetLightingOutput()
        lastFingerprint = nil
        statusFailureCount = 0
        lastError = message
        device.disconnect(reason: nil)
        issuedIDs.removeAll()
        scheduleReopen()
    }

    private func scheduleReopen() {
        guard isRunning, !suspendedForSystemInactivity, !secureInputPaused, reopenTask == nil else { return }
        reopenSequence &+= 1
        let sequence = reopenSequence
        reopenTask = Task { [weak self] in
            defer { if self?.reopenSequence == sequence { self?.reopenTask = nil } }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
                guard let self, self.isRunning, !self.suspendedForSystemInactivity,
                      !self.refreshSecureInput(), !Task.isCancelled else { return }
                if self.deviceConnected && self.hardwareInputReady { break }
                await self.openDevice()
                if self.deviceConnected && self.hardwareInputReady {
                    await self.forceRepaint()
                    break
                }
            }
        }
    }

    private func startSecureInputMonitor() {
        secureInputTask?.cancel()
        _ = refreshSecureInput()
        secureInputTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200_000_000) }
                catch { return }
                guard let self, self.isRunning, !self.suspendedForSystemInactivity else { return }
                _ = self.refreshSecureInput()
            }
        }
    }

    /// Metadata only: never changes system protection. Hardware events are
    /// discarded across this interval; Herdr/menu navigation stays independent.
    @discardableResult
    private func refreshSecureInput() -> Bool {
        let active = emulator == nil && SecureInputStatus.isActive
        let changed = inputGate.observe(secureInput: active)
        if secureInputPaused != active { secureInputPaused = active }
        if active { recoveryReadOnly = true; hardwareInputReady = false }
        if active && (changed || Date().timeIntervalSince(ownerCheckAt) >= 1) {
            ownerCheckAt = Date()
            let reported = SecureInputStatus.reportedApplication()
            if changed || reported != secureInputApplication {
                secureInputApplication = reported
                inputLogger.info("Secure Input active; reported association=\(reported ?? "unknown or exited application", privacy: .public)")
            }
        }
        if changed {
            hardwareInputReady = false
            secureInputPaused = active
            if active {
                recoveryReadOnly = true
                reopenSequence &+= 1
                reopenTask?.cancel(); reopenTask = nil
                wideKeysDown.removeAll()
                lastSubmitPressAt = nil
                layerLighting.reset()
                resetLightingOutput()
                lastFingerprint = nil
                activeLayerNumber = nil
                keymapReady = false
                deviceConnected = false
                // Release once. No light clear, flash write, or retries while
                // protected; releasing a handle does not disable Secure Input.
                device.disconnect(reason: nil)
                issuedIDs.removeAll()
                statusFailureCount = 0
            } else {
                secureInputApplication = nil
                inputLogger.info("Secure Input cleared; scheduling fresh hardware validation (no input replay)")
                scheduleReopen()
            }
        }
        return active
    }

    // MARK: - Herdr focus observation

    private func startFocusObservation() {
        guard terminalActivationObserver == nil else { return }
        terminalActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.suspendedForSystemInactivity else { return }
                self.schedule() // Refresh pane focus; never infer it from a pad slot.
            }
        }
    }

    private func stopFocusObservation() {
        if let terminalActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminalActivationObserver)
        }
        terminalActivationObserver = nil
    }


    private func schedule() {
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.config.debounce
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.debounceTask = nil
            await self.refresh()
        }
    }

    // MARK: - Repaint

    public func forceRepaint() async {
        lightingCache.invalidate()
        lastFingerprint = nil
        await refresh(forcePaint: true)
    }

    private func refresh(forcePaint: Bool = false, updateLayer: Bool = false) async {
        guard isRunning, !suspendedForSystemInactivity else { return }
        snapshotSequence += 1
        let sequence = snapshotSequence
        if updateLayer { _ = await updateDeviceStatus() }

        let fetched: [HerdrAgent]
        let observationSucceeded: Bool
        let observationError: String?
        do {
            let snapshot = try await HerdrClient.snapshot()
            fetched = snapshot.agents
            observationSucceeded = true
            observationError = snapshot.warning
        } catch {
            guard sequence == snapshotSequence else { return }
            fetched = []
            observationSucceeded = false
            observationError = error.localizedDescription
        }
        guard sequence == snapshotSequence, isRunning, !suspendedForSystemInactivity else { return }
        if observationSucceeded { onAgentSnapshot?(fetched) }
        else { onAgentObservationReset?() }
        if lastError != observationError { lastError = observationError }
        if agents != fetched { agents = fetched }
        let validPage = min(agentPage, agentPageCount - 1)
        if agentPage != validPage { agentPage = validPage }

        let selectedState = fetched.first(where: \.focused)?.status
        let aggregate = StatusMapper.aggregate(fetched, config)
        if aggregateState != aggregate { aggregateState = aggregate }
        let pageAgents = visibleAgents
        // Macro and voice keys share ids, so the binding decides each key's
        // light: configured text wins, the wide key falls back to voice.
        let flexKeys = (Pad.macroKeyIDs + Pad.voiceKeyIDs).map { key -> OAI.Thread in
            if keyBindings.text(for: key) != nil {
                return StatusMapper.macroThread(id: key, config)
            }
            if Pad.voiceKeyIDs.contains(key) {
                return StatusMapper.voiceThread(id: key, active: voiceActive, config)
            }
            if key == Pad.submitKeyID { return StatusMapper.macroThread(id: key, config) }
            return OAI.Thread(id: key, brightness: 0, effect: .off)
        }
        let threads = StatusMapper.threads(
            for: pageAgents,
            config,
            agentKeyIDs: padConfiguration.agentKeyIDs
        )
            + [StatusMapper.piActionThread(id: Pad.fastKeyID, color: config.fastColor, config),
               StatusMapper.piActionThread(id: Pad.approveKeyID, color: config.approveColor, config),
               StatusMapper.piActionThread(id: Pad.rejectKeyID, color: config.rejectColor, config),
               StatusMapper.piActionThread(id: Pad.splitKeyID, color: config.splitColor, config)]
            + flexKeys

        // Fingerprint the whole rendered picture, including the selected
        // agent's ring state (which can belong to an off-page agent).
        let fingerprint = threads.map { thread in
            "\(thread.id):\(thread.color ?? -1):\(thread.effect?.rawValue ?? -1):\(thread.brightness ?? -1)"
        }.joined(separator: "|") + "|ring:\(selectedState ?? "-")"

        if fingerprint != lastPublishedFingerprint {
            lastPublishedFingerprint = fingerprint
            publishKeyState(threads)
        }

        // Lighting is a global physical surface, not stored per layer. After
        // the one-shot departure clear, leave it entirely to Codex outside our
        // layer. Paint on entry and after evidence of another client's writes.
        guard isHerdrLayerActive else {
            lastFingerprint = nil
            return
        }
        guard forcePaint || fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        await apply(state: selectedState, threads: threads)
    }

    private func publishKeyState(_ threads: [OAI.Thread]) {
        var colors: [Int: Color] = [:]
        var effects: [Int: OAI.Effect] = [:]
        for thread in threads {
            guard let packed = thread.color, (thread.brightness ?? 0) > 0,
                  let effect = thread.effect, effect != .off else { continue }
            colors[thread.id] = Color(packedRGB: packed)
            effects[thread.id] = effect
        }
        keyColors = colors
        keyEffects = effects
    }

    private func apply(state: String?, threads: [OAI.Thread]) async {
        guard isRunning, deviceConnected, hardwareInputReady, !suspendedForSystemInactivity,
              !refreshSecureInput(), isHerdrLayerActive else { return }
        let zone = StatusMapper.zone(for: state, config) ?? .dark
        pendingLighting = PadLightingFrame(threads: threads,
                                            keys: config.driveBacklight ? zone : .dark, ambient: zone)
        guard lightingTask == nil else { return } // Latest picture wins, no backlog.
        let worker = lightingWorkerGeneration
        lightingTask = Task { [weak self] in await self?.flushLighting(worker: worker) }
    }

    private func resetLightingOutput() {
        lightingWorkerGeneration &+= 1
        lightingTask?.cancel()
        lightingTask = nil
        pendingLighting = nil
        lightingCache.invalidate()
    }

    private func flushLighting(worker: UInt64) async {
        defer { if worker == lightingWorkerGeneration { lightingTask = nil } }
        while worker == lightingWorkerGeneration, !Task.isCancelled {
            guard isRunning, deviceConnected, hardwareInputReady, !suspendedForSystemInactivity,
              !refreshSecureInput(), isHerdrLayerActive else { return }
            guard pendingLighting != nil else { return }
            // Input takes precedence. Dial/joystick bursts coalesce into one
            // final render after 120 ms of quiet instead of a render per event.
            let quietRemaining = 0.12 - (ProcessInfo.processInfo.systemUptime - lastInputAt)
            if quietRemaining > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(quietRemaining * 1_000_000_000)) }
                catch { return }
                continue
            }
            guard let frame = pendingLighting else { return }
            pendingLighting = nil
            let token = layerLighting.generation
            let delta = lightingCache.delta(for: frame)
            guard !delta.isEmpty else { continue }
            layerLighting.markPainting(managedLayer: herdrLayerNumber)
            func mayContinue() -> Bool {
                worker == lightingWorkerGeneration && !Task.isCancelled && isRunning
                    && deviceConnected && !suspendedForSystemInactivity
                    && layerLighting.mayPaint(token, managedLayer: herdrLayerNumber)
            }
            do {
                if !delta.threads.isEmpty {
                    let revision = lightingCache.revision
                    _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(delta.threads))
                    guard mayContinue() else { return }
                    if lightingCache.revision == revision { lightingCache.recordThreads(delta.threads) }
                }
                guard mayContinue() else { return }
                // Do not finish an obsolete frame or continue lighting writes
                // through a new input burst. Already-sent JSON is never split.
                if pendingLighting != nil { continue }
                if ProcessInfo.processInfo.systemUptime - lastInputAt < 0.12 {
                    pendingLighting = frame
                    continue
                }
                if lightingCache.delta(for: frame).zonesChanged {
                    let revision = lightingCache.revision
                    _ = try await device.callAsync(OAI.methodRGBConfig,
                        params: OAI.rgbConfigParams(keys: frame.keys, ambient: frame.ambient))
                    guard mayContinue() else { return }
                    if lightingCache.revision == revision { lightingCache.recordZones(frame) }
                }
            } catch {
                guard mayContinue() else { return }
                lastError = error.localizedDescription
                lightingCache.invalidate()
                lastFingerprint = nil // Retry on the normal poll, not in a tight loop.
                pendingLighting = nil
                return
            }
        }
    }

    /// One-shot stopgap: remove Herdr's picture on departure, without trying
    /// to synthesize Codex's state or trigger application actions. Codex may
    /// leave the pad dark until its next native lighting update.
    private func clearLightingForLayerHandoff(token: UInt64) async {
        func mayContinue() -> Bool {
            isRunning && deviceConnected && !suspendedForSystemInactivity
                && layerLighting.mayClear(token, managedLayer: herdrLayerNumber)
        }
        guard mayContinue() else { return }
        do {
            _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(offThreads()))
            // Re-entry, another layer change, disconnect, and sleep invalidate
            // the second half of this handoff. Never clear a newly painted layer.
            guard mayContinue() else { return }
            _ = try await device.callAsync(OAI.methodRGBConfig,
                                          params: OAI.rgbConfigParams(keys: .dark, ambient: .dark))
        } catch {
            guard mayContinue() else { return }
            lastError = "Layer lighting handoff: \(error.localizedDescription)"
        }
    }

    /// Thread state paints over zone state, so clearing the zones alone leaves
    /// the pad lit. Both have to go.
    private func allLightsOff() async {
        let threads = offThreads()
        _ = try? await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
        _ = try? await device.callAsync(
            OAI.methodRGBConfig,
            params: OAI.rgbConfigParams(keys: .dark, ambient: .dark)
        )
    }

    private func allLightsOffImmediately() {
        let threads = offThreads()
        device.call(OAI.methodThreads, params: OAI.threadsParams(threads))
        device.call(
            OAI.methodRGBConfig,
            params: OAI.rgbConfigParams(keys: .dark, ambient: .dark)
        )
    }

    private func offThreads() -> [OAI.Thread] {
        (0...Pad.maxThreadID).map {
            OAI.Thread(id: $0, brightness: 0, effect: .off, syncKeys: false, syncAmbient: false)
        }
    }

    // MARK: - Key presses

    /// Every bound key arrives here. Which key does what is the one place that
    /// has to agree with `Pad`, so keep the dispatch in a single switch.
    public func handleKeyPress(_ index: Int) {
        lastInputAt = ProcessInfo.processInfo.systemUptime
        if onKeyIntercept?(index) == true { return }
        if index == Pad.fastKeyID {
            onFastKey?()
        } else if index == Pad.approveKeyID {
            onApproveKey?()
        } else if index == Pad.rejectKeyID {
            onRejectKey?()
        } else if index == Pad.splitKeyID {
            onSplitKey?()
        } else if Pad.macroKeyIDs.contains(index) || Pad.voiceKeyIDs.contains(index) {
            // A configured text macro wins over the key's built-in role, which
            // is how the config file may repurpose the wide voice key.
            if let text = keyBindings.text(for: index) {
                Task { await injectPrompt(text) }
            } else if Pad.voiceKeyIDs.contains(index) {
                onVoiceKey?()
            } else if index == Pad.submitKeyID {
                Task { await submitFocusedPane() }
            }
        } else if index == Pad.dialUpID || index == Pad.dialDownID {
            onDial?(index == Pad.dialUpID ? 1 : -1)
        } else if index == Pad.dialClickID {
            onDialClick?()
        } else if let direction = Pad.JoystickDirection(keyID: index) {
            onJoystick?(direction)
        } else if let slot = padConfiguration.agentSlot(for: index) {
            Task { await focusSlot(slot) }
        }
    }

    /// Sends Enter to the focused Herdr pane.
    public func submitFocusedPane() async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let target = agent.focusTarget
            else {
                lastError = "Nothing has focus in Herdr right now."
                return
            }
            try await HerdrClient.sendKeys(target: target, keys: ["enter"])
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Types a macro string into the focused agent's prompt, unsubmitted —
    /// the human still reads it and presses enter.
    public func injectPrompt(_ text: String) async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let target = agent.focusTarget
            else {
                lastError = "Nothing has focus in Herdr right now."
                return
            }
            try await HerdrClient.typeText(target: target, text: text)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the voice key. Same contract as `setStackPanelOpen`.
    public func setVoiceActive(_ active: Bool) async {
        guard voiceActive != active else { return }
        voiceActive = active
        await refresh()
    }

    /// Lets app-layer features that fail outside the bridge surface their
    /// error where the menu already shows the bridge's own.
    public func noteError(_ message: String) {
        lastError = message
    }

    /// Shows the next tab of the Herdr app's current space.
    public func cycleTabs() async {
        do {
            try await HerdrClient.cycleTabs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the stack key. Called by the app when the window opens or
    /// closes, so the key reflects what is actually on screen.
    public func setStackPanelOpen(_ open: Bool) async {
        guard stackPanelOpen != open else { return }
        stackPanelOpen = open
        await refresh()
    }

    /// Repaints the land key. Same contract as `setStackPanelOpen`.
    public func setLandPanelOpen(_ open: Bool) async {
        guard landPanelOpen != open else { return }
        landPanelOpen = open
        await refresh()
    }

    /// Move the six-agent bank shown on the pad. Joystick east/right advances
    /// and west/left goes back; wrapping makes every bank reachable.
    public func scrollAgentPage(by delta: Int) {
        guard delta != 0, agentPageCount > 1 else { return }
        agentPage = (agentPage + delta % agentPageCount + agentPageCount) % agentPageCount
        lastFingerprint = nil
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    /// Slot N is the Nth agent in the currently visible bank, in the detected
    /// pad's reading order. The terminal comes forward with the focused pane.
    public func focusSlot(_ slot: Int) async {
        let index = agentPage * agentPageSize + slot
        guard slot >= 0, slot < agentPageSize, index < agents.count else { return }
        guard let target = agents[index].focusTarget else { return }
        do {
            try await HerdrClient.focusAgent(target)
            raiseTerminal()
            if isRunning { await refresh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Validate against a fresh snapshot before honoring an OS notification.
    /// This also works when the hardware bridge is off or the pad is unplugged.
    public func focusNotificationTarget(_ target: HerdrAgentTarget) async throws {
        let current = try await HerdrClient.listAgents()
        guard let index = current.firstIndex(where: { target.matches($0) }) else {
            throw HerdrError.api("The agent pane for this notification is no longer available.")
        }
        try await HerdrClient.focusAgent(target)
        agentPage = index / agentPageSize
        raiseTerminal()
        if isRunning { await refresh() }
    }

    public static var terminalBundleID: String {
        ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultTerminalBundleID
    }

    public static var terminalIsActive: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminalBundleID
    }

    /// The app Herdr's panes live in. Override with `WL_TERMINAL_BUNDLE_ID` if
    /// they live somewhere other than the Herdr desktop app.
    public static let defaultTerminalBundleID = "dev.herdr.app"

    /// Brings the terminal forward unless it is already the active app.
    ///
    /// Nothing is ever launched: the agent whose key was pressed is running in
    /// a pane of a terminal that is by definition already up, so a terminal
    /// that is not running means the bundle id is wrong, and opening a fresh
    /// window would not be what the key meant. macOS may refuse a background
    /// app's `activate` outright, which is what the second attempt is for —
    /// `openApplication` on an already-running app raises it the way `open -a`
    /// does.
    private func raiseTerminal() {
        let identifier = Self.terminalBundleID
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier).first
        else { return }
        guard !app.isActive else { return }
        if app.activate(options: []) { return }
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
