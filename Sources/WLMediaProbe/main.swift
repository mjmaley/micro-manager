import Foundation
import WLKit

/// Read-only diagnostic: no HID handle, microphone samples, or playback commands.
@main
struct MediaProbe {
    @MainActor
    static func main() async {
        let backend = NowPlayingMediaBackend()
        do {
            if let media = try await backend.snapshot() {
                print("Now Playing: \(media.identity.bundleID), pid \(media.identity.pid), playing=\(media.playing), identifiable=\(media.identity.isUsable)")
            } else {
                print("Now Playing: no session (helper access OK)")
            }
        } catch { print("Now Playing error: \(error.localizedDescription)") }

        let input = DictationInputMonitor()
        let watching = CommandLine.arguments.contains("--watch")
        if watching { print("Watching target microphone activity for 60 seconds (Ctrl-C to stop)…") }
        let deadline = Date().addingTimeInterval(watching ? 60 : 0)
        var previous: String?
        repeat {
            let message: String
            do {
                let apps = try input.activeApps()
                message = apps.isEmpty ? "Mic: idle" : "Mic: " + apps.sorted().joined(separator: ", ")
            } catch { message = "Mic error: \(error.localizedDescription)" }
            if message != previous {
                print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
                fflush(stdout)
                previous = message
            }
            if !watching { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
    }
}
