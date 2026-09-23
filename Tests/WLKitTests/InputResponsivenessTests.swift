import Foundation
import Testing
@testable import WLKit

struct InputResponsivenessTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test func blockedWriterDoesNotBlockMainQueueInput() async {
        let writer = HIDWriteQueue()
        let events = Events()
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writer.enqueue { _ in
                events.add(Thread.isMainThread ? "write-on-main" : "background-write")
                DispatchQueue.main.async {
                    events.add("input-delivered")
                    release.signal()
                }
                events.add(release.wait(timeout: .now() + 2) == .success ? "write-finished" : "input-starved")
                done.resume()
            }
        }
        #expect(events.values == ["background-write", "input-delivered", "write-finished"])
    }

    @Test func wholeMessagesRemainSerialized() async {
        let writer = HIDWriteQueue()
        let events = Events()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writer.enqueue { _ in
                events.add("a1")
                Thread.sleep(forTimeInterval: 0.01)
                events.add("a2")
            }
            writer.enqueue { _ in
                events.add("b1")
                Thread.sleep(forTimeInterval: 0.01)
                events.add("b2")
                done.resume()
            }
        }
        #expect(events.values == ["a1", "a2", "b1", "b2"])
    }

    @Test func disconnectSkipsQueuedMessagesButFinishesCurrentMessage() async {
        let writer = HIDWriteQueue()
        let events = Events()
        let release = DispatchSemaphore(value: 0)
        let token: UInt64 = await withCheckedContinuation { started in
            writer.enqueue { token in
                events.add("started")
                started.resume(returning: token)
                _ = release.wait(timeout: .now() + 3)
                events.add("finished")
            }
        }
        writer.enqueue { _ in events.add("stale-message") }
        let drain = Task.detached { writer.invalidateAndDrain() }
        let deadline = Date().addingTimeInterval(2)
        while writer.isCurrent(token), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(!writer.isCurrent(token))
        release.signal()
        await drain.value
        #expect(events.values == ["started", "finished"])
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writer.enqueue { next in
                events.add(next == token ? "old-connection" : "new-connection")
                done.resume()
            }
        }
        #expect(events.values.last == "new-connection")
    }

    @Test func synchronousShutdownWriteCannotInterleaveAQueuedMessage() {
        let writer = HIDWriteQueue()
        let events = Events()
        writer.enqueue { _ in
            events.add("async1")
            Thread.sleep(forTimeInterval: 0.01)
            events.add("async2")
        }
        writer.sync { events.add("shutdown") }
        #expect(events.values == ["async1", "async2", "shutdown"])
    }

    func frame() -> PadLightingFrame {
        PadLightingFrame(threads: (0..<13).map { OAI.Thread(id: $0, color: 0xFFFFFF, brightness: 1, effect: .solid) },
                         keys: .dark, ambient: OAI.Zone(color: 0xFFFFFF))
    }

    func primed(_ frame: PadLightingFrame) -> PadLightingCache {
        var cache = PadLightingCache()
        cache.recordThreads(frame.threads)
        cache.recordZones(frame)
        return cache
    }

    @Test func identicalPictureProducesNoWrites() {
        let picture = frame()
        #expect(primed(picture).delta(for: picture).isEmpty)
    }

    @Test func ringChangeDoesNotResendAnyAgentKeys() {
        let original = frame()
        let cache = primed(original)
        var updated = original
        updated.ambient.color = 0xFFA000
        let delta = cache.delta(for: updated)
        #expect(delta.threads.isEmpty)
        #expect(delta.zonesChanged)
    }

    @Test func oneAgentChangeSendsOnlyThatKeyWithoutZones() throws {
        let original = frame()
        let cache = primed(original)
        var updated = original
        updated.threads[3].color = 0x00C853
        let delta = cache.delta(for: updated)
        #expect(delta.threads.map(\.id) == [3])
        #expect(!delta.zonesChanged)
        let full = try JSONSerialization.data(withJSONObject: OAI.threadsParams(updated.threads))
        let small = try JSONSerialization.data(withJSONObject: OAI.threadsParams(delta.threads))
        #expect(small.count < full.count / 3)
    }

    @Test func unusedKeyStillGetsExplicitOffUpdate() {
        let original = frame()
        let cache = primed(original)
        var updated = original
        updated.threads[5] = OAI.Thread(id: 5, brightness: 0, effect: .off)
        let delta = cache.delta(for: updated)
        #expect(delta.threads.count == 1)
        #expect(delta.threads.first?.effect == .off)
    }

    @Test func foreignReadOnlyResponsesDoNotInvalidateLights() {
        let picture = frame()
        var cache = primed(picture)
        let revision = cache.revision
        for method in ["device.status", "sys.version", "config.read"] {
            let invalidated = cache.invalidate(method: method)
            #expect(!invalidated)
        }
        #expect(cache.revision == revision)
        #expect(cache.delta(for: picture).isEmpty)
    }

    @Test func foreignWritesInvalidateOnlyTheirLightingSurface() {
        let picture = frame()
        var keys = primed(picture)
        let keysInvalidated = keys.invalidate(method: OAI.methodThreads)
        #expect(keysInvalidated)
        #expect(keys.delta(for: picture).threads.count == 13)
        #expect(!keys.delta(for: picture).zonesChanged)
        var zones = primed(picture)
        let zonesInvalidated = zones.invalidate(method: OAI.methodRGBConfig)
        #expect(zonesInvalidated)
        #expect(zones.delta(for: picture).threads.isEmpty)
        #expect(zones.delta(for: picture).zonesChanged)
    }

    @Test func reconnectOrUnknownForeignWriteRequiresFullRefresh() {
        let picture = frame()
        var cache = primed(picture)
        let invalidated = cache.invalidate()
        #expect(invalidated)
        #expect(cache.delta(for: picture).threads.count == 13)
        #expect(cache.delta(for: picture).zonesChanged)
    }

    @Test func partialAcknowledgementDoesNotClaimUnsentZones() {
        let picture = frame()
        var cache = PadLightingCache()
        cache.recordThreads(picture.threads)
        #expect(cache.delta(for: picture).threads.isEmpty)
        #expect(cache.delta(for: picture).zonesChanged)
    }
}
