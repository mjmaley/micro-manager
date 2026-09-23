import Foundation

/// An intentionally conservative identity: never resume a different player or item.
public struct MediaSnapshot: Equatable, Sendable {
    public struct Identity: Equatable, Sendable {
        public let bundleID: String
        public let pid: Int
        public let itemID: String?
        public let title: String?
        public let artist: String?
        public let duration: Double?

        public init(bundleID: String, pid: Int, itemID: String? = nil,
                    title: String? = nil, artist: String? = nil, duration: Double? = nil) {
            self.bundleID = bundleID
            self.pid = pid
            self.itemID = itemID
            self.title = title
            self.artist = artist
            self.duration = duration
        }

        public var isUsable: Bool {
            !bundleID.isEmpty && pid > 0 && (!(itemID ?? "").isEmpty || !(title ?? "").isEmpty)
        }

        /// Brave regenerates Now Playing's contentItemIdentifier on transport
        /// changes. Allow that ONLY while confirming our pause, and only with
        /// matching player/process and sufficiently complete video metadata.
        /// Once confirmed, ownership uses strict identity equality again.
        func matchesDuringPause(_ other: Identity) -> Bool {
            if self == other { return true }
            guard bundleID == "com.brave.Browser", other.bundleID == bundleID,
                  pid == other.pid, let title, !title.isEmpty, other.title == title,
                  let artist, !artist.isEmpty, other.artist == artist,
                  let duration, duration.isFinite, duration > 0,
                  other.duration == duration,
                  !(itemID ?? "").isEmpty, !(other.itemID ?? "").isEmpty else { return false }
            return true
        }
    }

    public let identity: Identity
    public let playing: Bool
    public let elapsed: Double?
    public let playbackRate: Double?

    public init(identity: Identity, playing: Bool, elapsed: Double? = nil, playbackRate: Double? = nil) {
        self.identity = identity
        self.playing = playing
        self.elapsed = elapsed
        self.playbackRate = playbackRate
    }

    var isSettledPause: Bool { !playing && (playbackRate == nil || playbackRate == 0) }
}

@MainActor
public protocol DictationMediaBackend: AnyObject {
    func snapshot() async throws -> MediaSnapshot?
    func pause() async throws
    func play() async throws
}

/// Owns only a pause it issued AND subsequently observed. All backend work is
/// serialized by the caller's tick loop. Input updates may arrive during awaits.
/// No media-key toggles, no transport retries within a take, no restoration after sleep/off.
@MainActor
public final class DictationMediaSession {
    public private(set) var status = "Off"
    public private(set) var enabled = false
    public private(set) var recording = false
    private let backend: any DictationMediaBackend
    private let now: () -> Date
    private let waitForConfirmation: () async throws -> Void
    private var epoch: UInt64 = 0
    private var handledTake = false
    private var lease: MediaSnapshot?
    private var idleSince: Date?
    private var lastValidation = Date.distantPast
    private var ticking = false
    private var inputUnknownSince: Date?
    private var inputGapExpired = false

    private var idleIsStable: Bool {
        inputUnknownSince == nil && !recording
            && idleSince.map { now().timeIntervalSince($0) >= 0.6 } == true
    }

    public init(backend: any DictationMediaBackend, now: @escaping () -> Date = Date.init,
                waitForConfirmation: @escaping () async throws -> Void = {
                    try await Task.sleep(nanoseconds: 150_000_000)
                }) {
        self.backend = backend
        self.now = now
        self.waitForConfirmation = waitForConfirmation
    }

    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        epoch &+= 1
        lease = nil
        handledTake = false
        recording = false
        idleSince = nil
        inputUnknownSince = nil
        inputGapExpired = false
        status = value ? "Watching Codex and OpenWhispr" : "Off · any paused media stays paused"
    }

    /// A successful sample. After a read gap, require a fresh idle debounce and
    /// revalidate media; never count time with unknown input as idle time.
    public func setRecording(_ value: Bool) {
        expireInputGapIfNeeded()
        let recovered = inputUnknownSince != nil
        inputUnknownSince = nil
        inputGapExpired = false
        if value { idleSince = nil }
        else if recording || recovered || idleSince == nil { idleSince = now() }
        recording = value
        if recovered, lease != nil {
            lastValidation = .distantPast
            status = value ? "Recording · media paused" : "Mic recovered · waiting for stable idle"
        }
    }

    /// A short Core Audio read failure suspends decisions, not pause ownership.
    /// Prolonged uncertainty still abandons ownership and cannot trigger play.
    public func setInputUnavailable() {
        guard enabled else { return }
        if inputUnknownSince == nil {
            inputUnknownSince = now()
            inputGapExpired = false
            status = "Mic read interrupted · waiting for recovery"
        }
        idleSince = nil
        expireInputGapIfNeeded()
    }

    private func expireInputGapIfNeeded() {
        guard let since = inputUnknownSince, !inputGapExpired,
              now().timeIntervalSince(since) >= 2 else { return }
        inputGapExpired = true
        invalidate("Mic unavailable for 2s · automatic resume cancelled")
    }

    /// Lock/sleep, prolonged input uncertainty, and backend errors must not play.
    public func invalidate(_ reason: String) {
        epoch &+= 1
        lease = nil
        handledTake = true
        idleSince = recording ? nil : now()
        status = reason
    }

    public func tick() async {
        guard enabled, !ticking else { return }
        expireInputGapIfNeeded()
        guard inputUnknownSince == nil else { return }
        ticking = true
        defer { ticking = false }
        let token = epoch
        do {
            if recording && !handledTake {
                handledTake = true
                guard let before = try await backend.snapshot(), before.playing else {
                    if token == epoch, inputUnknownSince == nil { status = "Recording · no media playing" }
                    return
                }
                guard token == epoch, enabled else { return }
                guard inputUnknownSince == nil, recording else {
                    // No transport was issued yet. A recovered, still-active
                    // take may retry this read-only probe.
                    if inputUnknownSince != nil { handledTake = false }
                    return
                }
                guard before.identity.isUsable else {
                    status = "Recording · media identity unavailable; skipped"
                    return
                }
                guard DictationInputMonitor.targetNames[before.identity.bundleID] == nil else {
                    status = "Recording · dictation app audio left alone"
                    return
                }
                try await backend.pause()
                guard token == epoch, enabled else { return }
                await confirmPause(of: before, token: token)
            } else if let paused = lease {
                let mayResume = idleIsStable
                guard mayResume || now().timeIntervalSince(lastValidation) >= 0.75 else { return }
                let current = try await backend.snapshot()
                guard token == epoch, enabled, inputUnknownSince == nil else { return }
                lastValidation = now()
                guard let current, Self.stillOwns(paused, current) else {
                    lease = nil
                    status = "Playback changed · automatic resume cancelled"
                    return
                }
                // Recheck after the await: another take may already have started.
                if mayResume && idleIsStable {
                    lease = nil // At most one play attempt, including on failure.
                    try await backend.play()
                    guard token == epoch, enabled else { return }
                    status = "Media resumed"
                    // A new take during play must be eligible to pause again.
                    handledTake = false
                }
            } else if !recording, let idleSince, now().timeIntervalSince(idleSince) >= 0.6 {
                handledTake = false
            }
        } catch {
            guard token == epoch, enabled else { return }
            lease = nil
            status = "Media control unavailable · \(error.localizedDescription)"
        }
    }

    /// Now Playing can update playing, rate, and item ID in separate steps.
    /// Poll read-only for at most two seconds (plus one in-flight helper call),
    /// requiring two consistent, settled paused samples. Never resend Pause.
    private func confirmPause(of before: MediaSnapshot, token: UInt64) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var candidate: MediaSnapshot?
        var sawPaused = false
        var reason = "state did not settle"
        do {
            for _ in 0..<10 {
                guard ContinuousClock.now < deadline else { break }
                try await waitForConfirmation()
                guard token == epoch, enabled else { return }
                let after = try await backend.snapshot()
                guard token == epoch, enabled else { return }
                guard let after else {
                    candidate = nil
                    reason = "Now Playing session unavailable"
                    continue
                }
                guard before.identity.matchesDuringPause(after.identity) else {
                    status = "Pause not confirmed · player or media changed; resume skipped"
                    return
                }
                if after.playing {
                    if sawPaused {
                        status = "Pause not confirmed · playback restarted; resume skipped"
                        return
                    }
                    candidate = nil
                    reason = "player still reports playing"
                    continue
                }
                sawPaused = true
                guard after.isSettledPause else {
                    candidate = nil
                    reason = "playback rate still updating"
                    continue
                }
                if let candidate, candidate.identity == after.identity {
                    guard Self.stillOwns(candidate, after) else {
                        status = "Pause not confirmed · position changed; resume skipped"
                        return
                    }
                    lease = after
                    lastValidation = now()
                    if inputUnknownSince == nil { status = "Recording · media paused" }
                    return
                }
                candidate = after
                reason = "media identity still settling"
            }
            status = "Pause not confirmed · \(reason); resume skipped"
        } catch {
            guard token == epoch, enabled else { return }
            status = "Pause not confirmed · \(error.localizedDescription); resume skipped"
        }
    }

    static func stillOwns(_ paused: MediaSnapshot, _ current: MediaSnapshot) -> Bool {
        guard current.isSettledPause, current.identity == paused.identity else { return false }
        // Seeking while paused is a user intervention too. Small timestamp
        // rounding differences are normal; missing position is not guessed.
        switch (paused.elapsed, current.elapsed) {
        case let (.some(a), .some(b)): return abs(a - b) <= 1.0
        case (.none, .none): return true
        default: return false
        }
    }
}
