struct PadLightingFrame: Equatable {
    var threads: [OAI.Thread]
    var keys: OAI.Zone
    var ambient: OAI.Zone
}

/// Cache only acknowledged writes, independently for keys and zones. A focus
/// change that changes only the ring must not resend every per-key RPC fragment.
struct PadLightingCache {
    struct Delta {
        var threads: [OAI.Thread]
        var zonesChanged: Bool
        var isEmpty: Bool { threads.isEmpty && !zonesChanged }
    }

    private var threads: [Int: OAI.Thread] = [:]
    private var keys: OAI.Zone?
    private var ambient: OAI.Zone?
    private(set) var revision: UInt64 = 0

    func delta(for frame: PadLightingFrame) -> Delta {
        Delta(threads: frame.threads.filter { threads[$0.id] != $0 },
              zonesChanged: keys != frame.keys || ambient != frame.ambient)
    }

    mutating func recordThreads(_ written: [OAI.Thread]) {
        for thread in written { threads[thread.id] = thread }
    }

    mutating func recordZones(_ frame: PadLightingFrame) {
        keys = frame.keys
        ambient = frame.ambient
    }

    /// Returns whether this response could represent an external lighting write.
    /// Read-only status/version responses do not invalidate the rendered picture.
    @discardableResult
    mutating func invalidate(method: String? = nil) -> Bool {
        switch method {
        case OAI.methodThreads: threads.removeAll()
        case OAI.methodRGBConfig: keys = nil; ambient = nil
        case nil, OAI.methodPreview: threads.removeAll(); keys = nil; ambient = nil
        default: return false
        }
        revision &+= 1
        return true
    }
}
