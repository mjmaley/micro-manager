import AppKit
import CoreAudio
import Darwin

/// Reads input *activity flags*, not microphone samples. No recording, taps, or
/// global keyboard hooks. The caller polls at 200 ms to survive process restarts,
/// helper churn, audio-device changes, and missed Core Audio notifications.
@MainActor
public final class DictationInputMonitor {
    public static let targetNames = [
        "com.openai.codex": "Codex",
        "com.gizmolabs.openwhispr": "OpenWhispr",
    ]

    private var owners: [pid_t: (path: String, bundleID: String?)] = [:]

    public init() {}

    public func activeApps() throws -> Set<String> {
        guard #available(macOS 15.4, *) else {
            throw InputError.unavailable("Recording detection requires macOS 15.4 or newer")
        }
        let processes = try processList()
        var result = Set<String>()
        var livePIDs = Set<pid_t>()
        for object in processes {
            do {
                let pid = pid_t(bitPattern: try readUInt32(object, kAudioProcessPropertyPID, name: "process PID"))
                livePIDs.insert(pid)
                // Unrelated apps' input properties must not invalidate a
                // Codex/OpenWhispr recording session.
                guard let owner = targetOwner(pid: pid) else { continue }
                let input = try readUInt32(object, kAudioProcessPropertyIsRunningInput, name: "input activity")
                if input != 0 { result.insert(owner) }
            } catch InputError.coreAudio(let status, _) where status == kAudioHardwareBadObjectError {
                // A process disappearing between enumeration and inspection is normal.
                continue
            }
        }
        owners = owners.filter { livePIDs.contains($0.key) }
        return result
    }

    private func targetOwner(pid: pid_t) -> String? {
        // Audio often lives in an Electron helper rather than the main app.
        // Resolve the enclosing app bundles from its executable path;
        // substring/name matching would accidentally include CodexBar, etc.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.flatMap {
                Self.targetNames[$0] == nil ? nil : $0
            }
        }
        let path = String(cString: buffer)
        if let cached = owners[pid], cached.path == path { return cached.bundleID }
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        var owner: String?
        while url.path != "/" {
            if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier,
               Self.targetNames[id] != nil {
                owner = id
                break
            }
            url.deleteLastPathComponent()
        }
        owners[pid] = (path, owner)
        return owner
    }

    private func processList() throws -> [AudioObjectID] {
        do { return try readProcessList() }
        catch InputError.coreAudio(let status, _) where status == kAudioHardwareBadPropertySizeError {
            // HAL's process list can grow between its size and data reads.
            // Retry once with a new buffer; persistent failure remains unknown.
            return try readProcessList()
        }
    }

    private func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), context: "process list size")
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, context: "process list data")
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, name: String) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), context: "\(name), object \(object)")
        guard size == MemoryLayout<UInt32>.size else {
            throw InputError.unavailable("Unexpected Core Audio property size")
        }
        return value
    }

    private func check(_ status: OSStatus, context: String) throws {
        if status != noErr { throw InputError.coreAudio(status, context) }
    }

    public enum InputError: LocalizedError {
        case coreAudio(OSStatus, String)
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .coreAudio(let status, let context): return "Core Audio \(context) failed (\(status))"
            case .unavailable(let reason): return reason
            }
        }
    }
}
