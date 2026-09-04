import SwiftUI
import AppKit
import WLKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum InactivityReason: Hashable { case systemSleep, screenSleep, sessionInactive }

    private weak var bridge: BridgeController?
    private var observingSystemActivity = false
    private var inactivityReasons = Set<InactivityReason>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        AgentNotificationController.shared.installDelegate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func observeSystemActivity(for bridge: BridgeController) {
        self.bridge = bridge
        guard !observingSystemActivity else { return }
        observingSystemActivity = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(machineWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(machineDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidResign), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private func becameInactive(for reason: InactivityReason) {
        let wasActive = inactivityReasons.isEmpty
        inactivityReasons.insert(reason)
        if wasActive { bridge?.prepareForSystemInactivity() }
    }

    private func becameActive(for reason: InactivityReason) {
        inactivityReasons.remove(reason)
        if inactivityReasons.isEmpty { bridge?.resumeAfterSystemInactivity() }
    }

    @objc private func machineWillSleep(_ notification: Notification) { becameInactive(for: .systemSleep) }
    @objc private func machineDidWake(_ notification: Notification) { becameActive(for: .systemSleep) }
    @objc private func screenDidSleep(_ notification: Notification) { becameInactive(for: .screenSleep) }
    @objc private func screenDidWake(_ notification: Notification) { becameActive(for: .screenSleep) }
    @objc private func sessionDidResign(_ notification: Notification) { becameInactive(for: .sessionInactive) }
    @objc private func sessionDidBecomeActive(_ notification: Notification) { becameActive(for: .sessionInactive) }
}

@main
struct MicroManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var bridge = BridgeController()
    @State private var didConfigure = false

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(bridge)
        } label: {
            // The label exists for the lifetime of the menu-bar item; the panel
            // content does not. Starting here lets a login-item launch begin
            // driving immediately without requiring the user to open the menu.
            Image(nsImage: MenuBarIcon.image(for: MenuBarIcon.State.from(bridge)))
                .task { await configureAndStart() }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private func configureAndStart() async {
        guard !didConfigure else { return }
        didConfigure = true

        delegate.observeSystemActivity(for: bridge)
        await AgentNotificationController.shared.configure(bridge: bridge)

        let piControls = PiControlController.shared
        piControls.onError = { [weak bridge] message in bridge?.noteError(message) }
        bridge.onFastKey = { piControls.allowForSession() }
        bridge.onApproveKey = { piControls.approve() }
        bridge.onRejectKey = { piControls.reject() }
        bridge.onSplitKey = { piControls.split() }

        let voice = VoiceController.shared
        voice.onActiveChange = { [weak bridge] active in
            Task { await bridge?.setVoiceActive(active) }
        }
        voice.onError = { [weak bridge] message in bridge?.noteError(message) }
        bridge.onVoiceKey = { voice.handleVoiceKey() }

        let tune = TuneController.shared
        tune.onError = { [weak bridge] message in bridge?.noteError(message) }
        tune.bindings = { [weak bridge] in bridge?.keyBindings ?? KeyBindings() }
        bridge.onDial = { step in tune.handleDial(step) }
        bridge.onDialClick = { tune.handleDialClick() }
        bridge.onJoystick = { direction in tune.handleJoystick(direction) }
        tune.onAgentPage = { [weak bridge] delta in
            bridge?.scrollAgentPage(by: delta)
        }

        // Choose the transport before starting: `useEmulator` rebuilds the
        // device, so doing it afterward would tear down a fresh connection.
        await bridge.useEmulator(BridgeSettings.emulate)

        // Come back up in whatever state it was left in. Defaults to on for a
        // first run.
        if BridgeSettings.enabled, !bridge.isRunning { await bridge.start() }
    }
}

/// Persisted across launches.
enum BridgeSettings {
    private static let key = "bridgeEnabled"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static let emulateKey = "emulatePad"

    /// Drive a virtual pad instead of the hardware. `WL_EMULATE=1` forces it on
    /// for a single run, which is what makes `swift run` useful with no device
    /// plugged in.
    static var emulate: Bool {
        get {
            if ProcessInfo.processInfo.environment["WL_EMULATE"] == "1" { return true }
            return UserDefaults.standard.bool(forKey: emulateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: emulateKey) }
    }
}
