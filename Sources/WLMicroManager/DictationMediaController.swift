import AppKit
import Combine
import os
import WLKit

/// Independent of the HID bridge/layer: keyboard and native Codex recording
/// still work when the pad is disconnected or Herdr's layer is not selected.
@MainActor
final class DictationMediaController: ObservableObject {
    static let shared = DictationMediaController()
    private static let preference = "pauseMediaDuringDictation"

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: preference)
    @Published private(set) var status = "Off" {
        didSet {
            if status != oldValue { logger.info("Media status: \(self.status, privacy: .public)") }
        }
    }
    @Published private(set) var inputStatus = ""
    @Published private(set) var lastInputError = ""
    @Published private(set) var diagnostic = ""
    @Published private(set) var checking = false
    var onRecordingChange: ((Bool?) -> Void)?

    private let logger = Logger(subsystem: "cc.worklouder.micromanager", category: "DictationMedia")
    private let input = DictationInputMonitor()
    private let backend = NowPlayingMediaBackend()
    private lazy var session = DictationMediaSession(backend: backend)
    private var inputTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var suspended = false
    private var inputHealthy = false

    func start() {
        guard inputTask == nil else { return }
        reconcile()
        inputTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleInput()
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
        mediaTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.inputHealthy {
                    await self.session.tick()
                    if self.enabled && !self.suspended { self.status = self.session.status }
                }
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.preference)
        diagnostic = ""
        lastInputError = ""
        reconcile()
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        reconcile()
    }

    private func reconcile() {
        inputHealthy = false
        inputStatus = ""
        onRecordingChange?(nil)
        session.setEnabled(enabled && !suspended)
        status = suspended && enabled ? "Suspended · no automatic resume after lock/sleep" : session.status
    }

    private func sampleInput() {
        guard enabled, !suspended else { return }
        do {
            let apps = try input.activeApps()
            inputHealthy = true
            session.setRecording(!apps.isEmpty)
            onRecordingChange?(!apps.isEmpty)
            inputStatus = apps.isEmpty ? "Mic: idle" : "Mic: " + apps.compactMap { DictationInputMonitor.targetNames[$0] }.sorted().joined(separator: ", ")
        } catch {
            let message = error.localizedDescription
            if inputHealthy || lastInputError != message {
                logger.error("Microphone read failed: \(message, privacy: .public)")
            }
            inputHealthy = false
            lastInputError = message // Keep the cause visible even after recovery.
            session.setInputUnavailable()
            status = session.status
            inputStatus = "Mic: temporarily unknown"
            // Keep the last observed light during a short gap instead of
            // switching back to button-count guessing while a take is active.
        }
    }

    /// Explicit read-only diagnostic; never issues a transport command.
    func checkMedia() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            if let media = try await backend.snapshot() {
                diagnostic = "Media access OK: \(media.identity.bundleID) · \(media.playing ? "playing" : "paused")"
            } else {
                diagnostic = "Media access OK · no Now Playing session"
            }
        } catch {
            diagnostic = error.localizedDescription
        }
    }
}
