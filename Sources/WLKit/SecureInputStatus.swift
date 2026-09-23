import AppKit
import Carbon
import IOKit

/// Read-only system metadata. Never enables/disables Secure Input or reads keys.
public enum SecureInputStatus {
    public static var isActive: Bool { IsSecureEventInputEnabled() }

    /// The console session's reported association can be stale. Only resolve
    /// a running app; never present an exited/reused/unresolved PID as certain.
    static func reportedApplication() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOResources"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOConsoleUsers" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let users = value as? [[String: Any]] else { return nil }
        for user in users where (user["kCGSSessionOnConsoleKey"] as? Bool) == true {
            guard let number = user["kCGSSessionSecureInputPID"] as? NSNumber,
                  number.int64Value > 0, number.int64Value <= Int64(Int32.max),
                  let app = NSRunningApplication(processIdentifier: number.int32Value),
                  !app.isTerminated else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown application"
            return "\(name) (PID \(number.int32Value))"
        }
        return nil
    }
}

/// Every interruption invalidates input accepted before it. Clearing Secure
/// Input alone is insufficient: a fresh connection/layer/keymap must validate.
struct HardwareInputGate {
    private(set) var secureInputActive = false
    private(set) var ready = false
    private(set) var generation: UInt64 = 0

    @discardableResult
    mutating func observe(secureInput active: Bool) -> Bool {
        guard active != secureInputActive else { return false }
        secureInputActive = active
        invalidate()
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        ready = false
    }

    @discardableResult
    mutating func validated(_ token: UInt64) -> Bool {
        guard token == generation, !secureInputActive else { return false }
        ready = true
        return true
    }

    func accepts(_ token: UInt64) -> Bool {
        ready && !secureInputActive && token == generation
    }
}
