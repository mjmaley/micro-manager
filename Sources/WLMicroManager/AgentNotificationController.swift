import AppKit
import UserNotifications
import OSLog
import WLKit

/// Owns notifications under MicroManager's signed bundle identity. No shell
/// callback, AppleScript, terminal-notifier, or model-supplied command is used.
@MainActor
final class AgentNotificationController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationController()
    private static let enabledKey = "agentNotificationsEnabled"
    private let logger = Logger(subsystem: "cc.worklouder.micromanager", category: "notifications")
    private var hasRequestedAuthorization = false

    @Published private(set) var enabled = UserDefaults.standard.object(forKey: enabledKey) == nil
        ? true : UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var status = "Checking notification permission…"
    @Published private(set) var authorized = false

    private let isBundled = Bundle.main.bundleURL.pathExtension == "app"
    // UNUserNotificationCenter can abort in an unbundled `swift run` process.
    private lazy var center = UNUserNotificationCenter.current()
    private weak var bridge: BridgeController?
    private var tracker = AgentNotificationTracker()
    private var current: [AgentNotificationTarget: HerdrAgent] = [:]
    private var lastTerminalActive: Bool?
    private var pending: [String: Task<Void, Never>] = [:]
    private var queuedClick: AgentNotificationTarget?
    private var revision = 0

    /// Install before didFinishLaunching so clicking an alert can cold-launch
    /// the app. Its payload survives relaunch; no transient agent index is used.
    func installDelegate() {
        guard isBundled else { return }
        center.delegate = self
    }

    func configure(bridge: BridgeController) async {
        self.bridge = bridge
        bridge.onAgentSnapshot = { [weak self] agents, identity in
            self?.observe(agents, identity: identity)
        }
        bridge.onAgentObservationReset = { [weak self] in self?.reset() }
        if let target = queuedClick {
            queuedClick = nil
            await focus(target)
        }
        await refreshPermission(requestIfNeeded: enabled)
    }

    func refreshPermission(requestIfNeeded: Bool = false) async {
        guard isBundled else {
            authorized = false
            status = "Notifications require the installed MicroManager.app."
            return
        }
        var settings = await center.notificationSettings()
        if requestIfNeeded && !hasRequestedAuthorization && settings.authorizationStatus == .notDetermined {
            hasRequestedAuthorization = true
            do { _ = try await center.requestAuthorization(options: [.alert]) }
            catch {
                authorized = false
                status = "Notification permission: \(error.localizedDescription)"
                logger.error("Permission request failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            settings = await center.notificationSettings()
        }
        logger.notice("Authorization status: \(settings.authorizationStatus.rawValue, privacy: .public)")
        authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if !enabled {
            status = "Agent notifications are off."
        } else if authorized {
            status = "Clicks focus the matching Herdr pane."
        } else {
            status = "Allow Micro Manager in System Settings → Notifications."
        }
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        reset()
        if !value && isBundled {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }
        await refreshPermission(requestIfNeeded: value)
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reset() {
        revision += 1
        tracker.reset()
        current.removeAll()
        lastTerminalActive = nil
        for (id, task) in pending {
            task.cancel()
            center.removePendingNotificationRequests(withIdentifiers: [id])
        }
        pending.removeAll()
    }

    private func observe(_ agents: [HerdrAgent], identity: String) {
        guard enabled, isBundled else { return }
        let socket = HerdrClient.socketPath()
        let terminalActive = BridgeController.terminalIsActive
        var next: [AgentNotificationTarget: HerdrAgent] = [:]
        for agent in agents {
            if let target = AgentNotificationTarget(agent: agent, socketPath: socket, socketIdentity: identity) {
                next[target] = agent
            }
        }
        // Herdr may emit several events per second. No Notification Center
        // IPC is needed when neither the snapshot nor host focus changed.
        guard next != current || lastTerminalActive != terminalActive else { return }
        lastTerminalActive = terminalActive
        // Remove outdated automatic alerts when the pane disappears, resumes
        // work, or is already being viewed. Test alerts are intentionally exempt.
        let obsolete = Set(current.keys).union(next.keys).filter { target in
            guard let agent = next[target] else { return true }
            return agent.status == "working" || (agent.focused && terminalActive)
        }
        for target in obsolete {
            pending.removeValue(forKey: target.identifier)?.cancel()
        }
        let ids = obsolete.map(\.identifier)
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
        current = next
        for event in tracker.consume(agents, socketPath: socket, socketIdentity: identity, terminalActive: terminalActive) {
            post(target: event.target, agent: event.agent, kind: event.kind)
        }
    }

    private func post(
        target: AgentNotificationTarget, agent: HerdrAgent,
        kind: AgentNotificationEvent.Kind, test: Bool = false
    ) {
        let id = (test ? "test-" : "") + target.identifier
        pending[id]?.cancel()
        let observedRevision = revision
        pending[id] = Task { [weak self] in
            guard let self else { return }
            await self.refreshPermission(requestIfNeeded: true)
            guard self.enabled, self.authorized, !Task.isCancelled,
                  self.revision == observedRevision else { return }
            if !test {
                guard let live = self.current[target], live.status == agent.status,
                      !(live.focused && BridgeController.terminalIsActive) else { return }
            }
            do {
                let content = UNMutableNotificationContent()
                let label = String(agent.agent.prefix(60))
                content.title = test ? "Herdr pane click test" : "\(label) \(kind == .attention ? "needs attention" : "finished")"
                content.subtitle = String(agent.shortName.prefix(100)) + " · pane " + String(target.paneID.suffix(8))
                content.body = test
                    ? "Click to focus this agent in Herdr and return to your terminal."
                    : (kind == .attention ? "Waiting for your input. Click to open this pane." : "Ready to review. Click to open this pane.")
                content.threadIdentifier = target.identifier
                content.userInfo = ["herdrTarget": try JSONEncoder().encode(target)]
                // Herdr can keep playing its existing sounds. Do not double them.
                let trigger = test ? UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false) : nil
                try await self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                self.logger.notice("Notification scheduled (test: \(test, privacy: .public))")
                if (Task.isCancelled || self.revision != observedRevision)
                    && self.pending[id]?.isCancelled != false {
                    self.center.removePendingNotificationRequests(withIdentifiers: [id])
                    self.center.removeDeliveredNotifications(withIdentifiers: [id])
                }
            } catch {
                self.status = "Notification failed: \(error.localizedDescription)"
            }
        }
    }

    /// Prefer another pane so a click visibly demonstrates target selection.
    /// A per-agent context menu can supply an exact target instead.
    func sendTest(paneID: String? = nil) async {
        guard enabled else { return }
        guard isBundled else { await refreshPermission(); return }
        do {
            let socket = HerdrClient.socketPath()
            guard let identity = AgentNotificationTarget.socketIdentity(at: socket) else {
                throw HerdrError.api("Herdr's socket is not available.")
            }
            let agents = try await HerdrClient.listAgents()
            let agent = paneID.flatMap { id in agents.first { $0.paneID == id } }
                ?? (paneID == nil ? agents.first { !$0.focused } ?? agents.first : nil)
            guard let agent,
                  let target = AgentNotificationTarget(agent: agent, socketPath: socket, socketIdentity: identity),
                  identity == AgentNotificationTarget.socketIdentity(at: socket) else {
                throw HerdrError.api("No matching Herdr agent is available for a test.")
            }
            post(target: target, agent: agent, kind: .attention, test: true)
        } catch { status = error.localizedDescription }
    }

    private func focus(_ target: AgentNotificationTarget) async {
        guard let bridge else { queuedClick = target; return }
        do {
            try await bridge.focusNotificationTarget(target)
            logger.notice("Notification click focused a validated Herdr pane")
        } catch {
            bridge.noteError(error.localizedDescription)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Herdr pane unavailable"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let data = response.notification.request.content.userInfo["herdrTarget"] as? Data,
              let target = try? JSONDecoder().decode(AgentNotificationTarget.self, from: data) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            await self.focus(target)
            completionHandler()
        }
    }
}
