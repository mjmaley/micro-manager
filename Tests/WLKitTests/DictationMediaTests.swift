import Foundation
import Testing
@testable import WLKit

@Suite(.serialized)
@MainActor
struct DictationMediaTests {
    final class Clock {
        var date = Date(timeIntervalSince1970: 100)
        func advance(_ seconds: Double = 1) { date.addTimeInterval(seconds) }
    }

    final class Backend: DictationMediaBackend {
        var value: MediaSnapshot? = DictationMediaTests.media()
        var snapshots: [MediaSnapshot?] = []
        var pauses = 0
        var plays = 0
        var fail = false
        var ignoresPause = false
        var onRead: (() -> Void)?
        var onPause: (() -> Void)?
        var onPlay: (() -> Void)?

        func snapshot() async throws -> MediaSnapshot? {
            let captured = snapshots.isEmpty ? value : snapshots.removeFirst()
            onRead?()
            if fail { throw NowPlayingMediaBackend.MediaError.unavailable("test failure") }
            return captured
        }
        func pause() async throws {
            pauses += 1
            if !ignoresPause, let value {
                self.value = .init(identity: value.identity, playing: false, elapsed: value.elapsed)
            }
            onPause?()
        }
        func play() async throws {
            plays += 1
            if let value { self.value = .init(identity: value.identity, playing: true, elapsed: value.elapsed) }
            onPlay?()
        }
    }

    static func media(playing: Bool = true, item: String = "video-1", pid: Int = 42,
                      elapsed: Double = 12, bundle: String = "com.brave.Browser") -> MediaSnapshot {
        .init(identity: .init(bundleID: bundle, pid: pid, itemID: item, title: "Video"),
              playing: playing, elapsed: elapsed)
    }

    func fixture() -> (Backend, Clock, DictationMediaSession) {
        let backend = Backend()
        let clock = Clock()
        let session = DictationMediaSession(backend: backend, now: { clock.date }, waitForConfirmation: {})
        session.setEnabled(true)
        return (backend, clock, session)
    }

    @Test func pauseAndResumeOnlyOnceAfterIdleDebounce() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        await session.tick()
        #expect(backend.pauses == 1)
        session.setRecording(false)
        await session.tick()
        #expect(backend.plays == 0)
        clock.advance()
        await session.tick()
        await session.tick()
        #expect(backend.plays == 1)
    }

    @Test func nothingPlayingNeverSendsTransport() async {
        for value in [nil, Self.media(playing: false)] {
            let (backend, clock, session) = fixture()
            backend.value = value
            session.setRecording(true)
            await session.tick()
            session.setRecording(false)
            clock.advance()
            await session.tick()
            #expect(backend.pauses == 0)
            #expect(backend.plays == 0)
        }
    }

    @Test func unidentifiableMediaIsSkipped() async {
        let (backend, _, session) = fixture()
        backend.value = .init(identity: .init(bundleID: "com.brave.Browser", pid: 42), playing: true)
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 0)
    }

    @Test func dictationAppMediaIsNotPaused() async {
        let (backend, _, session) = fixture()
        backend.value = Self.media(bundle: "com.openai.codex")
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 0)
    }

    @Test func changedItemPlayerSeekOrManualPlaybackCancelsResume() async {
        let changes: [MediaSnapshot?] = [nil,
            Self.media(playing: false, item: "video-2"), Self.media(playing: false, pid: 100),
            Self.media(playing: false, elapsed: 99),
            Self.media(playing: false, bundle: "com.spotify.client"), Self.media(playing: true)]
        for changed in changes {
            let (backend, clock, session) = fixture()
            session.setRecording(true)
            await session.tick()
            backend.value = changed
            clock.advance()
            await session.tick()
            // Returning to the original session must not reclaim ownership.
            backend.value = Self.media(playing: false)
            session.setRecording(false)
            clock.advance()
            await session.tick()
            #expect(backend.plays == 0)
        }
    }

    @Test func playbackChangeImmediatelyBeforeResumeIsDetected() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        session.setRecording(false)
        backend.value = Self.media(playing: false, item: "new")
        clock.advance()
        await session.tick()
        #expect(backend.plays == 0)
    }

    @Test func overlappingOrRapidTakesKeepOnePause() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        // The input monitor reports the union of both apps' active inputs.
        session.setRecording(true)
        session.setRecording(false)
        clock.advance(0.2)
        await session.tick()
        session.setRecording(true)
        clock.advance()
        await session.tick()
        #expect(backend.pauses == 1)
        #expect(backend.plays == 0)
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 1)
    }

    @Test func nextTakeCanPauseAgain() async {
        let (backend, clock, session) = fixture()
        for _ in 0..<2 {
            session.setRecording(true)
            await session.tick()
            session.setRecording(false)
            clock.advance()
            await session.tick()
        }
        #expect(backend.pauses == 2)
        #expect(backend.plays == 2)
    }

    @Test func unconfirmedPauseIsNotResumedOrRetried() async {
        let (backend, clock, session) = fixture()
        backend.ignoresPause = true
        session.setRecording(true)
        await session.tick()
        clock.advance()
        await session.tick()
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.pauses == 1)
        #expect(backend.plays == 0)
    }

    @Test func disableAndInputFailureAbandonOwnership() async {
        for disable in [true, false] {
            let (backend, clock, session) = fixture()
            session.setRecording(true)
            await session.tick()
            if disable { session.setEnabled(false) }
            else { session.invalidate("Input unknown") }
            session.setRecording(false)
            clock.advance()
            await session.tick()
            #expect(backend.plays == 0)
        }
    }

    @Test func backendFailureDoesNotToggleOrRetryUntilNextTake() async {
        let (backend, clock, session) = fixture()
        backend.fail = true
        session.setRecording(true)
        await session.tick()
        backend.fail = false
        clock.advance()
        await session.tick()
        #expect(backend.pauses == 0)
        session.setRecording(false)
        clock.advance()
        await session.tick()
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 1)
    }

    @Test func recordingEndsDuringProbeDoesNotPause() async {
        let (backend, _, session) = fixture()
        backend.onRead = { session.setRecording(false) }
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 0)
    }

    @Test func disableDuringProbeDoesNotPause() async {
        let (backend, _, session) = fixture()
        backend.onRead = { session.setEnabled(false) }
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 0)
    }

    @Test func disableDuringPauseDoesNotAcquireLeaseOrResume() async {
        let (backend, clock, session) = fixture()
        backend.onPause = { session.setEnabled(false) }
        session.setRecording(true)
        await session.tick()
        session.setEnabled(true)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 0)
    }

    @Test func newTakeDuringResumeProbePreventsPlay() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        session.setRecording(false)
        clock.advance()
        backend.onRead = { session.setRecording(true) }
        await session.tick()
        #expect(backend.plays == 0)
        #expect(backend.pauses == 1)
    }

    @Test func newTakeDuringPlayCanPauseAgain() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        session.setRecording(false)
        clock.advance()
        backend.onPlay = { session.setRecording(true) }
        await session.tick()
        await session.tick()
        #expect(backend.pauses == 2)
    }

    @Test func unknownInputWhileIdleCanRecover() async {
        let (backend, clock, session) = fixture()
        session.invalidate("Input unknown")
        clock.advance()
        await session.tick()
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 1)
    }

    @Test func shortInputGapPreservesPauseButRequiresFreshStableIdle() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        session.setRecording(false)
        clock.advance(0.5)
        session.setInputUnavailable()
        clock.advance(1)
        await session.tick()
        #expect(backend.plays == 0)
        session.setRecording(false)
        clock.advance(0.5)
        await session.tick()
        #expect(backend.plays == 0)
        clock.advance(0.2)
        await session.tick()
        #expect(backend.pauses == 1)
        #expect(backend.plays == 1)
    }

    @Test func inputGapRecoveryWhileStillRecordingDoesNotResume() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        session.setInputUnavailable()
        clock.advance(0.5)
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 1)
        #expect(backend.plays == 0)
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 1)
    }

    @Test func longInputGapAbandonsPauseEvenIfNextSampleRecovers() async {
        for tickDuringGap in [false, true] {
            let (backend, clock, session) = fixture()
            session.setRecording(true)
            await session.tick()
            session.setInputUnavailable()
            clock.advance(2.1)
            if tickDuringGap { await session.tick() }
            session.setRecording(false)
            clock.advance()
            await session.tick()
            #expect(backend.plays == 0)
        }
    }

    @Test func repeatedShortGapsCannotCountAsStableIdle() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        for _ in 0..<5 {
            session.setInputUnavailable()
            clock.advance(0.3)
            session.setRecording(false)
            clock.advance(0.3)
            await session.tick()
            #expect(backend.plays == 0)
        }
        clock.advance()
        await session.tick()
        #expect(backend.plays == 1)
    }

    @Test func inputGapDuringResumeProbeRequiresNewIdleDebounce() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        session.setRecording(false)
        clock.advance()
        backend.onRead = {
            session.setInputUnavailable()
            session.setRecording(false)
        }
        await session.tick()
        #expect(backend.plays == 0)
        backend.onRead = nil
        clock.advance()
        await session.tick()
        #expect(backend.plays == 1)
    }

    @Test func inputGapDuringStartProbeDoesNotPauseUntilKnown() async {
        let (backend, clock, session) = fixture()
        backend.onRead = { session.setInputUnavailable() }
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 0)
        backend.onRead = nil
        clock.advance(0.2)
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 1)
    }

    @Test func inputGapDuringPauseCanRecoverConfirmedOwnership() async {
        let (backend, clock, session) = fixture()
        backend.onPause = { session.setInputUnavailable() }
        session.setRecording(true)
        await session.tick()
        clock.advance(0.2)
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 1)
    }

    @Test func changedMediaDuringInputGapStillCancelsResume() async {
        let (backend, clock, session) = fixture()
        session.setRecording(true)
        await session.tick()
        session.setInputUnavailable()
        backend.value = Self.media(playing: false, item: "other")
        clock.advance(0.3)
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 0)
    }

    static func brave(item: String, playing: Bool = false, rate: Double = 0,
                      title: String = "Video", bundle: String = "com.brave.Browser") -> MediaSnapshot {
        .init(identity: .init(bundleID: bundle, pid: 42, itemID: item, title: title,
                             artist: "Channel", duration: 1487.421),
              playing: playing, elapsed: 1264.9, playbackRate: rate)
    }

    @Test func observedBravePauseTransitionSettlesBeforeAcquiringOwnership() async {
        let (backend, clock, session) = fixture()
        let playing = Self.brave(item: "playing-id", playing: true, rate: 1)
        let settled = Self.brave(item: "paused-id")
        backend.snapshots = [playing, playing,
                             Self.brave(item: "playing-id", rate: 1),
                             Self.brave(item: "intermediate-id"), settled, settled]
        session.setRecording(true)
        await session.tick()
        #expect(backend.pauses == 1)
        #expect(session.status == "Recording · media paused")
        backend.value = settled
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 1)
    }

    @Test func nonzeroRateCannotConfirmPauseEvenWhenPlayingIsFalse() async {
        let (backend, clock, session) = fixture()
        backend.snapshots = [Self.brave(item: "old", playing: true, rate: 1)]
            + Array(repeating: Self.brave(item: "old", rate: 1), count: 10)
        session.setRecording(true)
        await session.tick()
        #expect(session.status.contains("playback rate still updating"))
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.pauses == 1)
        #expect(backend.plays == 0)
    }

    @Test func changingBraveVideoDuringConfirmationCancelsResume() async {
        let (backend, clock, session) = fixture()
        backend.snapshots = [Self.brave(item: "old", playing: true, rate: 1),
                             Self.brave(item: "new", title: "Different video")]
        session.setRecording(true)
        await session.tick()
        #expect(session.status.contains("player or media changed"))
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 0)
    }

    @Test func braveIDAllowanceIsLimitedToPauseTransition() async {
        let (backend, clock, session) = fixture()
        let settled = Self.brave(item: "settled")
        backend.snapshots = [Self.brave(item: "playing", playing: true, rate: 1), settled, settled]
        session.setRecording(true)
        await session.tick()
        #expect(session.status == "Recording · media paused")
        backend.value = Self.brave(item: "another-id")
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.plays == 0)
        #expect(session.status.contains("Playback changed"))
    }

    @Test func transitionIdentityFallbackRequiresBraveAndCompleteMetadata() {
        #expect(Self.brave(item: "old").identity.matchesDuringPause(Self.brave(item: "new").identity))
        #expect(!Self.brave(item: "old", bundle: "com.spotify.client").identity.matchesDuringPause(
            Self.brave(item: "new", bundle: "com.spotify.client").identity))
        #expect(!Self.media(item: "old").identity.matchesDuringPause(Self.media(item: "new").identity))
        #expect(!Self.brave(item: "old").identity.matchesDuringPause(Self.brave(item: "new", title: "Other").identity))
    }

    @Test func playbackRestartDuringConfirmationIsNeverRepausedOrResumed() async {
        let (backend, clock, session) = fixture()
        let playing = Self.brave(item: "playing", playing: true, rate: 1)
        backend.snapshots = [playing, Self.brave(item: "paused"), playing]
        session.setRecording(true)
        await session.tick()
        #expect(session.status.contains("playback restarted"))
        session.setRecording(false)
        clock.advance()
        await session.tick()
        #expect(backend.pauses == 1)
        #expect(backend.plays == 0)
    }

    @Test func installedHelperProtocolUsesExplicitCommandsAndLiteralArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-test-\(UUID()) space")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("helper.pl")
        let log = root.appendingPathComponent("commands")
        // A fake Perl helper, not the installed adapter: no real media commands.
        try """
        my $log = shift @ARGV;
        if ($ARGV[0] eq 'get') {
            print '{"playing":true,"bundleIdentifier":"test.player","processIdentifier":42,"title":"Test"}';
        } else {
            open(my $fh, '>>', $log) or die $!;
            print $fh join(' ', @ARGV), "\\n";
        }
        """.write(to: script, atomically: true, encoding: .utf8)
        let backend = NowPlayingMediaBackend(adapter: { .init(script: script, framework: log) })
        #expect(try await backend.snapshot()?.identity.bundleID == "test.player")
        try await backend.pause()
        try await backend.play()
        #expect(try String(contentsOf: log, encoding: .utf8) == "send 1\nsend 0\n")
    }

    @Test func helperFailureAndTimeoutFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("helper.pl")
        let backend = NowPlayingMediaBackend(adapter: { .init(script: script, framework: root) })
        for source in ["exit 1;", "print 'not json';", "sleep 10;"] {
            try source.write(to: script, atomically: true, encoding: .utf8)
            let start = Date()
            await #expect(throws: (any Error).self) { try await backend.snapshot() }
            #expect(Date().timeIntervalSince(start) < 5)
        }
    }

    @Test func decoderRequiresExplicitStateAndPlayer() throws {
        #expect(try NowPlayingMediaBackend.decode(Data("null".utf8)) == nil)
        for text in ["", "{}", "{\"playing\":true}", "{\"playing\":\"true\"}"] {
            #expect(throws: (any Error).self) { try NowPlayingMediaBackend.decode(Data(text.utf8)) }
        }
        let text = """
        {"playing":true,"bundleIdentifier":"com.brave.Browser","processIdentifier":42,
         "contentItemIdentifier":"video-1","title":"Video","elapsedTime":12}
        """
        #expect(try NowPlayingMediaBackend.decode(Data(text.utf8)) == Self.media())
    }
}
