import AppKit
import Foundation

/// Uses the mediaremote-adapter already shipped with OpenWhispr. No private
/// framework is linked into MicroManager, and no helper is downloaded at runtime.
/// This optional integration fails closed when that installation changes or the
/// OS denies access. It never falls back to a play/pause key event.
@MainActor
public final class NowPlayingMediaBackend: DictationMediaBackend {
    public struct Adapter: Sendable {
        public let script: URL
        public let framework: URL

        public init(script: URL, framework: URL) {
            self.script = script
            self.framework = framework
        }
    }

    private let adapter: @MainActor () throws -> Adapter

    public init(adapter: @escaping @MainActor () throws -> Adapter = NowPlayingMediaBackend.installedAdapter) {
        self.adapter = adapter
    }

    public static func installedAdapter() throws -> Adapter {
        var apps: [URL] = []
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.gizmolabs.openwhispr") {
            apps.append(installed)
        }
        apps.append(URL(fileURLWithPath: "/Applications/OpenWhispr.app"))
        apps.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OpenWhispr.app"))
        for app in apps {
            let bin = app.appendingPathComponent("Contents/Resources/bin")
            let script = bin.appendingPathComponent("mediaremote-adapter.pl")
            let framework = bin.appendingPathComponent("MediaRemoteAdapter.framework")
            if FileManager.default.fileExists(atPath: script.path),
               FileManager.default.fileExists(atPath: framework.appendingPathComponent("MediaRemoteAdapter").path) {
                return Adapter(script: script, framework: framework)
            }
        }
        throw MediaError.unavailable("OpenWhispr's media helper was not found")
    }

    public func snapshot() async throws -> MediaSnapshot? {
        try Self.decode(await run(["get", "--no-artwork"]))
    }

    public func pause() async throws { _ = try await run(["send", "1"]) }
    public func play() async throws { _ = try await run(["send", "0"]) }

    private func run(_ arguments: [String]) async throws -> Data {
        let paths = try adapter()
        // Pipe reads never block the UI or the microphone monitor. The adapter
        // has a hard deadline; stderr and artwork are intentionally not collected.
        return try await Task.detached(priority: .utility) {
            try Self.execute(paths: paths, arguments: arguments)
        }.value
    }

    nonisolated private static func execute(paths: Adapter, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script.path, paths.framework.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: deadline)
        defer { deadline.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw MediaError.unavailable("media helper failed or timed out")
        }
        return data
    }

    public nonisolated static func decode(_ data: Data) throws -> MediaSnapshot? {
        struct Payload: Decodable {
            let bundleIdentifier: String?
            let processIdentifier: Int?
            let contentItemIdentifier: String?
            let title: String?
            let artist: String?
            let duration: Double?
            let elapsedTime: Double?
            let playbackRate: Double?
            let playing: Bool
        }
        // A literal null is the helper's explicit 'no session', not an error.
        guard let payload = try JSONDecoder().decode(Payload?.self, from: data) else { return nil }
        guard let bundleID = payload.bundleIdentifier, let pid = payload.processIdentifier else {
            throw MediaError.unavailable("Now Playing did not identify its player")
        }
        return MediaSnapshot(identity: .init(bundleID: bundleID, pid: pid,
                                             itemID: payload.contentItemIdentifier,
                                             title: payload.title, artist: payload.artist,
                                             duration: payload.duration),
                             playing: payload.playing, elapsed: payload.elapsedTime,
                             playbackRate: payload.playbackRate)
    }

    public enum MediaError: LocalizedError {
        case unavailable(String)
        public var errorDescription: String? {
            switch self { case .unavailable(let message): return message }
        }
    }
}
