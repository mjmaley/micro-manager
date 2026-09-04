import Foundation
import IOKit
import IOKit.hid
import WLKit

private enum ProbeError: LocalizedError {
    case badArguments(String)
    case badResponse(String)
    case missingLayer(Int)
    case missingKey(Int)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .badArguments(let message), .badResponse(let message), .verificationFailed(let message):
            return message
        case .missingLayer(let layer):
            return "The active profile does not have Layer \(layer)."
        case .missingKey(let key):
            return "Key \(key) is not present in the device matrix."
        }
    }
}

private struct DeviceKeymap {
    let raw: [String: Any]
    let text: String
    let config: [String: Any]

    init(_ response: Any?) throws {
        guard let raw = response as? [String: Any],
              let text = raw["data"] as? String,
              let data = text.data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ProbeError.badResponse("Device returned an unreadable keymap.json.") }
        self.raw = raw
        self.text = text
        self.config = config
    }
}

@main
struct WLLayerProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first ?? "inspect" {
            case "inspect":
                try await inspect()
            case "probe":
                let layer = try positiveInt(arguments, at: 1, default: 2, name: "layer")
                let key = try nonnegativeInt(arguments, at: 2, default: 0, name: "key")
                let seconds = try positiveInt(arguments, at: 3, default: 30, name: "seconds")
                try await probe(layerNumber: layer, keyID: key, seconds: seconds)
            case "watch":
                let seconds = try positiveInt(arguments, at: 1, default: 30, name: "seconds")
                try await watch(seconds: seconds)
            case "apply":
                let layer = try positiveInt(arguments, at: 1, default: 2, name: "layer")
                try await applyFullMap(layerNumber: layer)
            case "restore":
                guard arguments.count == 2 else {
                    throw ProbeError.badArguments("Usage: WLLayerProbe restore <backup-file>")
                }
                try await restoreFullBackup(at: arguments[1])
            default:
                throw ProbeError.badArguments(usage)
            }
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            if error.localizedDescription.localizedCaseInsensitiveContains("privilege")
                || error.localizedDescription.localizedCaseInsensitiveContains("permitted")
                || error.localizedDescription.localizedCaseInsensitiveContains("Input Monitoring") {
                fputs("Grant Input Monitoring to the terminal or WLLayerProbe, then quit and relaunch it.\n", stderr)
            }
            exit(1)
        }
    }

    private static let usage = """
    Usage:
      WLLayerProbe inspect
      WLLayerProbe probe [layer=2] [key=0] [seconds=30]
      WLLayerProbe watch [seconds=30]
      WLLayerProbe apply [layer=2]
      WLLayerProbe restore <backup-file>
    """

    private static func positiveInt(_ args: [String], at index: Int, default fallback: Int, name: String) throws -> Int {
        guard args.count > index else { return fallback }
        guard let value = Int(args[index]), value > 0 else {
            throw ProbeError.badArguments("\(name) must be a positive integer.")
        }
        return value
    }

    private static func nonnegativeInt(_ args: [String], at index: Int, default fallback: Int, name: String) throws -> Int {
        guard args.count > index else { return fallback }
        guard let value = Int(args[index]), value >= 0 else {
            throw ProbeError.badArguments("\(name) must be a non-negative integer.")
        }
        return value
    }

    private static func connect() async throws -> WLDevice {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access != kIOHIDAccessTypeGranted {
            print("Input Monitoring is not granted; requesting it now…")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let device = WLDevice()
        try device.connect()
        guard let info = device.info else { throw WLDevice.Failure.notConnected }
        print("Device: \(info.product) (PID \(String(format: "0x%04X", info.productID)), \(info.transport))")
        return device
    }

    private static func readStatus(_ device: WLDevice) async throws -> [String: Any] {
        guard let status = try await device.callAsync("device.status") as? [String: Any] else {
            throw ProbeError.badResponse("device.status returned an unexpected response.")
        }
        return status
    }

    private static func readKeymap(_ device: WLDevice) async throws -> DeviceKeymap {
        try DeviceKeymap(await device.callAsync("fs.read", params: ["file": "keymap.json"]))
    }

    private static func inspect() async throws {
        let device = try await connect()
        defer { device.disconnect(reason: nil) }
        let version = try await device.callAsync("sys.version")
        let status = try await readStatus(device)
        let keymap = try await readKeymap(device)
        print("Firmware: \(compactJSON(version))")
        print("Status: \(compactJSON(status))")
        printLayerSummary(keymap.config)
    }

    private static func printLayerSummary(_ config: [String: Any]) {
        let profileIndex = max(0, config["activeProfileId"] as? Int ?? 0)
        guard let profiles = config["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            print("No profiles in keymap.")
            return
        }
        let profile = profiles[min(profileIndex, profiles.count - 1)]
        print("Active profile: \(profileIndex + 1) — \(profile["name"] as? String ?? "unnamed")")
        guard let layers = profile["layers"] as? [[String: Any]] else { return }
        for (index, layer) in layers.enumerated() {
            let name = layer["name"] as? String ?? "Layer \(index + 1)"
            let bindings = agentBindings(in: layer)
            print("  Layer \(index + 1) — \(name): \(bindings.isEmpty ? "no key AG bindings" : bindings.joined(separator: ", "))")
            if let layout = layer["layout"] as? [String: Any] {
                let encoder = (layout["encoders"] as? [[String]])?.flatMap { $0 }
                    .filter { $0.hasPrefix("KV_OAI_AG") } ?? []
                let joystick = ((layout["joystick"] as? [String: Any])?["sectors"] as? [[String: Any]])?
                    .compactMap { $0["k"] as? String }.filter { $0.hasPrefix("KV_OAI_AG") } ?? []
                if !encoder.isEmpty { print("    encoder: \(encoder.joined(separator: ", "))") }
                if !joystick.isEmpty { print("    joystick: \(joystick.joined(separator: ", "))") }
            }
        }
    }

    private static func agentBindings(in layer: [String: Any]) -> [String] {
        guard let layout = layer["layout"] as? [String: Any],
              let rows = layout["keymap"] as? [[String]] else { return [] }
        var result: [String] = []
        var key = 0
        for row in rows {
            for code in row {
                if code.hasPrefix("KV_OAI_AG") { result.append("key \(key)=\(code)") }
                key += 1
            }
        }
        return result
    }

    private static func watch(seconds: Int) async throws {
        let device = try await connect()
        defer { device.disconnect(reason: nil) }
        print("Watching all device notifications for \(seconds) seconds…")
        device.onNotification = { method, params in
            print("\(method): \(compactJSON(params))")
            fflush(stdout)
        }
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    private static func applyFullMap(layerNumber: Int) async throws {
        let device = try await connect()
        defer { device.disconnect(reason: nil) }
        let original = try await readKeymap(device)
        let backup = try saveBackup(original.text)
        print("Full keymap backup: \(backup.path)")
        let changed = try await KeymapManager.apply(device, layerIndex: layerNumber - 1)
        let after = try await readKeymap(device)
        print("Layer \(layerNumber) Herdr map \(changed ? "applied" : "already present").")
        printLayerSummary(after.config)
    }

    private static func probe(layerNumber: Int, keyID: Int, seconds: Int) async throws {
        guard let position = Pad.position(of: keyID) else { throw ProbeError.missingKey(keyID) }
        let device = try await connect()
        defer { device.disconnect(reason: nil) }

        let original = try await readKeymap(device)
        let backup = try saveBackup(original.text)
        print("Full keymap backup: \(backup.path)")

        let originalCode = try keyCode(in: original.config, layerNumber: layerNumber, at: position)
        let probeCode = "KV_OAI_AG" + String(format: "%02d", keyID)
        print("Layer \(layerNumber), key \(keyID): \(originalCode) → \(probeCode)")

        do {
            let modified = try replacingKey(
                in: original.config,
                layerNumber: layerNumber,
                at: position,
                with: probeCode
            )
            try await writeKeymap(device, config: modified)
            let verified = try await readKeymap(device)
            guard try keyCode(in: verified.config, layerNumber: layerNumber, at: position) == probeCode else {
                throw ProbeError.verificationFailed("Firmware acknowledged the write but did not retain the Layer \(layerNumber) binding.")
            }

            print("Probe binding verified. Switch the device to Layer \(layerNumber) and press key \(keyID).")
            print("The key should alternate cyan/purple while that layer is active. Watching for \(seconds) seconds…")

            var receivedPress = false
            var foreignResponses = 0
            var issuedIDs = Set<Int>()
            device.onTX = { _, _, id in issuedIDs.insert(id) }
            device.onResponse = { id, _, _ in
                if issuedIDs.remove(id) == nil { foreignResponses += 1 }
            }
            device.onNotification = { method, params in
                guard method == OAI.notifyHID, let payload = params as? [String: Any] else { return }
                print("HID notification: \(compactJSON(payload))")
                if OAI.agIndex(payload["k"] as? String) == keyID, (payload["act"] as? Int) == 1 {
                    receivedPress = true
                }
            }

            let started = Date()
            var lastWireLayer: Int?
            var paint = false
            var activeSamples = 0
            while Date().timeIntervalSince(started) < Double(seconds) {
                let status = try await readStatus(device)
                let wireLayer = status["layer_index"] as? Int
                if wireLayer != lastWireLayer {
                    print("device.status layer_index = \(wireLayer.map(String.init) ?? "missing")")
                    lastWireLayer = wireLayer
                }
                // Existing firmware reports this field one-based. The explicit comparison
                // keeps this experiment honest rather than silently painting every layer.
                if wireLayer == layerNumber {
                    activeSamples += 1
                    paint.toggle()
                    let thread = OAI.Thread(
                        id: keyID,
                        color: paint ? 0x00E5FF : 0xB000FF,
                        brightness: 1,
                        effect: .solid,
                        speed: 0
                    )
                    _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams([thread]))
                }
                try await Task.sleep(nanoseconds: 750_000_000)
            }

            print("Probe result: target-layer samples=\(activeSamples), matching key press=\(receivedPress ? "yes" : "no"), foreign RPC responses=\(foreignResponses)")
        } catch {
            print("Probe failed; attempting targeted restoration before exiting…")
            try? await restoreKey(device, layerNumber: layerNumber, position: position, originalCode: originalCode)
            throw error
        }

        try await restoreKey(device, layerNumber: layerNumber, position: position, originalCode: originalCode)
        print("Restored Layer \(layerNumber), key \(keyID) to \(originalCode).")
        print("If visual state remains stale, switch layers once so the owning application repaints it.")
    }

    private static func restoreKey(
        _ device: WLDevice,
        layerNumber: Int,
        position: (row: Int, column: Int),
        originalCode: String
    ) async throws {
        // Re-read first and restore only the one field touched by the probe. This
        // preserves unrelated edits another application may have made meanwhile.
        let current = try await readKeymap(device)
        let restored = try replacingKey(
            in: current.config,
            layerNumber: layerNumber,
            at: position,
            with: originalCode
        )
        try await writeKeymap(device, config: restored)
        let verified = try await readKeymap(device)
        guard try keyCode(in: verified.config, layerNumber: layerNumber, at: position) == originalCode else {
            throw ProbeError.verificationFailed("Targeted key restoration was not retained. Use the printed backup with the restore command.")
        }
    }

    private static func profileAndLayer(
        _ config: [String: Any],
        layerNumber: Int
    ) throws -> (profiles: [[String: Any]], profileIndex: Int, layers: [[String: Any]], layerIndex: Int) {
        guard let profiles = config["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw ProbeError.badResponse("Device keymap contains no profiles.")
        }
        let requestedProfile = max(0, config["activeProfileId"] as? Int ?? 0)
        let profileIndex = min(requestedProfile, profiles.count - 1)
        guard let layers = profiles[profileIndex]["layers"] as? [[String: Any]],
              layerNumber > 0, layerNumber <= layers.count else {
            throw ProbeError.missingLayer(layerNumber)
        }
        return (profiles, profileIndex, layers, layerNumber - 1)
    }

    private static func keyCode(
        in config: [String: Any],
        layerNumber: Int,
        at position: (row: Int, column: Int)
    ) throws -> String {
        let parts = try profileAndLayer(config, layerNumber: layerNumber)
        guard let layout = parts.layers[parts.layerIndex]["layout"] as? [String: Any],
              let rows = layout["keymap"] as? [[String]],
              position.row < rows.count,
              position.column < rows[position.row].count else {
            throw ProbeError.missingKey(position.row + position.column)
        }
        return rows[position.row][position.column]
    }

    private static func replacingKey(
        in config: [String: Any],
        layerNumber: Int,
        at position: (row: Int, column: Int),
        with code: String
    ) throws -> [String: Any] {
        var result = config
        var parts = try profileAndLayer(result, layerNumber: layerNumber)
        var layer = parts.layers[parts.layerIndex]
        guard var layout = layer["layout"] as? [String: Any],
              var rows = layout["keymap"] as? [[String]],
              position.row < rows.count,
              position.column < rows[position.row].count else {
            throw ProbeError.missingKey(position.row + position.column)
        }
        rows[position.row][position.column] = code
        layout["keymap"] = rows
        layer["layout"] = layout
        parts.layers[parts.layerIndex] = layer
        parts.profiles[parts.profileIndex]["layers"] = parts.layers
        result["profiles"] = parts.profiles
        return result
    }

    private static func writeKeymap(_ device: WLDevice, config: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProbeError.badResponse("Could not encode keymap JSON.")
        }
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": text])
    }

    private static func saveBackup(_ text: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".probe-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = root.appendingPathComponent("keymap-\(stamp).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func restoreFullBackup(at path: String) async throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        guard let data = text.data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.badArguments("Backup is not a valid keymap JSON document.")
        }
        let device = try await connect()
        defer { device.disconnect(reason: nil) }
        try await writeKeymap(device, config: config)
        print("Restored full keymap from \(path).")
    }

    private static func compactJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value ?? NSNull())
        }
        return text
    }
}
