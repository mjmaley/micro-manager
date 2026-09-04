import Foundation

/// Device keymap handling.
///
/// Per-key lighting only works on keys bound to `KV_OAI_AG*` keycodes on the
/// layer that owns the integration. Nothing reports a mismatch:
/// `v.oai.thstatus` still answers `{"ok":1}` for a key that cannot light, so a
/// wrong keymap looks exactly like a working one from the host side. Creator
/// Micro 2 uses Layer 1; Codex Micro preserves Codex on Layer 1 and uses Layer 2.
///
/// The file itself is double-encoded: `fs.read` returns `{"data": "<json>"}`
/// where the inner string is the real config.
public enum KeymapManager {

    /// Indexed by key: key N is bound to `agCodes[N]`.
    public static let agCodes = [
        "KV_OAI_AG00", "KV_OAI_AG01", "KV_OAI_AG02",
        "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05",
        "KV_OAI_AG06", "KV_OAI_AG07", "KV_OAI_AG08",
        "KV_OAI_AG09", "KV_OAI_AG10", "KV_OAI_AG11",
        "KV_OAI_AG12",
    ]

    /// The dial: clockwise, counter-clockwise, and press. Layer 2 ships with
    /// an unbound press on Codex Micro, so AG19 completes the selector control.
    static let dialCodes = ["KV_OAI_AG13", "KV_OAI_AG14", "KV_OAI_AG19"]

    /// The joystick's four cardinal sectors, matched by the angle at their
    /// centre in the radial map. Diagonal sectors are left alone.
    static let joystickCodes: [(centre: Double, code: String)] = [
        (0.25, "KV_OAI_AG15"),
        (0.50, "KV_OAI_AG16"),
        (0.75, "KV_OAI_AG17"),
        (0.00, "KV_OAI_AG18"),
    ]

    /// Standard eight-way radial sectors. Codex Micro's empty Layer 2 ships
    /// with only a north sector and one catch-all sector, so east/west cannot
    /// be rebound without splitting that catch-all. Existing behavior at each
    /// diagonal is preserved when the split is needed.
    static let radialSectors: [(centre: Double, a1: Double, a2: Double)] = [
        (0.25, 0.1875, 0.3125),
        (0.375, 0.3125, 0.4375),
        (0.50, 0.4375, 0.5625),
        (0.625, 0.5625, 0.6875),
        (0.75, 0.6875, 0.8125),
        (0.875, 0.8125, 0.9375),
        (0.00, 0.9375, 0.0625),
        (0.125, 0.0625, 0.1875),
    ]

    /// A sector's centre angle, handling the one that wraps through zero.
    static func sectorCentre(_ a1: Double, _ a2: Double) -> Double {
        let centre = a2 >= a1 ? (a1 + a2) / 2 : ((a1 + a2 + 1) / 2)
        return centre.truncatingRemainder(dividingBy: 1)
    }

    static func sector(_ sector: [String: Any], contains angle: Double) -> Bool {
        guard let a1 = sector["a1"] as? Double, let a2 = sector["a2"] as? Double else { return false }
        return a2 >= a1 ? angle >= a1 && angle < a2 : angle >= a1 || angle < a2
    }

    static func withJoystickCodes(_ sectors: [[String: Any]]) -> [[String: Any]] {
        let hasAllCardinals = joystickCodes.allSatisfy { wanted in
            sectors.contains { sector in
                guard let a1 = sector["a1"] as? Double, let a2 = sector["a2"] as? Double else { return false }
                return abs(sectorCentre(a1, a2) - wanted.centre) < 0.01
            }
        }

        if hasAllCardinals {
            return sectors.map { original in
                var sector = original
                if let a1 = sector["a1"] as? Double, let a2 = sector["a2"] as? Double,
                   let match = joystickCodes.first(where: { abs($0.centre - sectorCentre(a1, a2)) < 0.01 }) {
                    sector["k"] = match.code
                }
                return sector
            }
        }

        return radialSectors.map { standard in
            let code = joystickCodes.first(where: { abs($0.centre - standard.centre) < 0.01 })?.code
                ?? sectors.first(where: { sector($0, contains: standard.centre) })?["k"] as? String
                ?? "KC_NONE"
            return ["k": code, "a1": standard.a1, "a2": standard.a2]
        }
    }

    /// The keycode each managed key must carry, addressed by its position in
    /// the [2, 4, 4, 3] matrix. Bindings are per key rather than per row: the
    /// stack key shares row 2 with three keys this app has no business
    /// touching, and rewriting the row would take their keycodes with it.
    static var bindings: [(row: Int, column: Int, code: String)] {
        Pad.boundKeyIDs.compactMap { key in
            guard key < agCodes.count, let at = Pad.position(of: key) else { return nil }
            return (at.row, at.column, agCodes[key])
        }
    }

    public enum Failure: LocalizedError {
        case noProfiles
        case noLayer(Int)
        case notAccepted
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noProfiles: return "Device keymap has no profiles."
            case .noLayer(let number): return "Device keymap has no Layer \(number)."
            case .notAccepted: return "The device did not accept the agent keymap."
            case .unreadable(let detail): return "Could not read the device keymap: \(detail)"
            }
        }
    }

    // MARK: - Parsing

    /// Unwraps the `{"data": "<json string>"}` envelope.
    public static func parse(_ raw: Any?) throws -> [String: Any] {
        guard let dict = raw as? [String: Any] else {
            throw Failure.unreadable("unexpected response shape")
        }
        guard let inner = dict["data"] as? String,
              let data = inner.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.unreadable("missing or malformed `data` field")
        }
        return config
    }

    static func layerKeymap(_ config: [String: Any], layerIndex: Int = 0) -> [[String]]? {
        guard layerIndex >= 0 else { return nil }
        let index = config["activeProfileId"] as? Int ?? 0
        guard let profiles = config["profiles"] as? [[String: Any]] else { return nil }
        let profile = index >= 0 && index < profiles.count ? profiles[index] : profiles.first
        guard let layers = profile?["layers"] as? [[String: Any]],
              layerIndex < layers.count,
              let layout = layers[layerIndex]["layout"] as? [String: Any],
              let keymap = layout["keymap"] as? [[String]]
        else { return nil }
        return keymap
    }

    static func layerLayout(_ config: [String: Any], layerIndex: Int = 0) -> [String: Any]? {
        guard layerIndex >= 0 else { return nil }
        let index = config["activeProfileId"] as? Int ?? 0
        guard let profiles = config["profiles"] as? [[String: Any]] else { return nil }
        let profile = index >= 0 && index < profiles.count ? profiles[index] : profiles.first
        guard let layers = profile?["layers"] as? [[String: Any]], layerIndex < layers.count else { return nil }
        return layers[layerIndex]["layout"] as? [String: Any]
    }

    // Compatibility helpers for Creator Micro 2 callers and tests.
    static func activeLayerKeymap(_ config: [String: Any]) -> [[String]]? { layerKeymap(config) }
    static func activeLayerLayout(_ config: [String: Any]) -> [String: Any]? { layerLayout(config) }

    /// True when every managed key, the dial and the joystick's cardinal
    /// sectors carry their AG codes on the selected Herdr layer.
    public static func isAgentKeymapApplied(_ config: [String: Any], layerIndex: Int = 0) -> Bool {
        guard let keymap = layerKeymap(config, layerIndex: layerIndex) else { return false }
        for binding in bindings {
            guard binding.row < keymap.count,
                  binding.column < keymap[binding.row].count,
                  keymap[binding.row][binding.column] == binding.code
            else { return false }
        }

        guard let layout = layerLayout(config, layerIndex: layerIndex),
              let encoders = layout["encoders"] as? [[String]],
              let dial = encoders.first,
              dial.count >= dialCodes.count,
              Array(dial.prefix(dialCodes.count)) == dialCodes,
              let joystick = layout["joystick"] as? [String: Any],
              let sectors = joystick["sectors"] as? [[String: Any]]
        else { return false }
        for (centre, code) in joystickCodes {
            let bound = sectors.contains { sector in
                guard let a1 = sector["a1"] as? Double,
                      let a2 = sector["a2"] as? Double
                else { return false }
                return abs(sectorCentre(a1, a2) - centre) < 0.01
                    && sector["k"] as? String == code
            }
            if !bound { return false }
        }
        return true
    }

    /// Rebinds the managed keys, leaving every other key, layer, encoder,
    /// joystick and lighting setting untouched.
    public static func withAgentKeymap(_ config: [String: Any], layerIndex: Int = 0) throws -> [String: Any] {
        var next = config
        let index = next["activeProfileId"] as? Int ?? 0
        guard var profiles = next["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw Failure.noProfiles
        }
        let profileIndex = index >= 0 && index < profiles.count ? index : 0
        var profile = profiles[profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]], !layers.isEmpty else {
            throw Failure.noProfiles
        }
        guard layerIndex >= 0, layerIndex < layers.count else {
            throw Failure.noLayer(layerIndex + 1)
        }
        var layer = layers[layerIndex]
        guard var layout = layer["layout"] as? [String: Any],
              var keymap = layout["keymap"] as? [[String]]
        else { throw Failure.noProfiles }

        for binding in bindings
        where binding.row < keymap.count && binding.column < keymap[binding.row].count {
            keymap[binding.row][binding.column] = binding.code
        }

        // The dial's rotation slots and press.
        if var encoders = layout["encoders"] as? [[String]],
           var dial = encoders.first, dial.count >= dialCodes.count {
            for index in dialCodes.indices { dial[index] = dialCodes[index] }
            encoders[0] = dial
            layout["encoders"] = encoders
        }

        // The joystick's cardinal sectors; diagonals keep their behavior.
        // A sparse Codex Micro layer is expanded to the standard eight sectors.
        if var joystick = layout["joystick"] as? [String: Any],
           let sectors = joystick["sectors"] as? [[String: Any]] {
            joystick["type"] = "RADIAL"
            joystick["sectors"] = withJoystickCodes(sectors)
            layout["joystick"] = joystick
        }

        layout["keymap"] = keymap
        layer["layout"] = layout
        layers[layerIndex] = layer
        profile["layers"] = layers
        profiles[profileIndex] = profile
        next["profiles"] = profiles
        return next
    }

    // MARK: - Device I/O

    /// Saves the exact pre-change configuration before any flash write. These
    /// backups are deliberately outside the app bundle so an update cannot
    /// remove them.
    @discardableResult
    static func saveBackup(_ config: [String: Any], device: WLDevice) throws -> URL {
        let base = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/micromanager/keymap-backups")
        try FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let serial = (device.info?.serial.isEmpty == false ? device.info!.serial : "device")
            .replacingOccurrences(of: "/", with: "-")
        let url = URL(fileURLWithPath: base).appendingPathComponent("\(serial)-\(stamp).json")
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func read(_ device: WLDevice) async throws -> [String: Any] {
        let raw = try await device.callAsync("fs.read", params: ["file": "keymap.json"])
        return try parse(raw)
    }

    /// Returns true when it had to change something.
    @discardableResult
    public static func apply(_ device: WLDevice, layerIndex: Int = 0) async throws -> Bool {
        let config = try await read(device)
        if isAgentKeymapApplied(config, layerIndex: layerIndex) { return false }

        _ = try saveBackup(config, device: device)
        let next = try withAgentKeymap(config, layerIndex: layerIndex)
        let encoded = try JSONSerialization.data(withJSONObject: next)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw Failure.unreadable("could not encode keymap")
        }
        _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": text])

        let after = try await read(device)
        guard isAgentKeymapApplied(after, layerIndex: layerIndex) else { throw Failure.notAccepted }
        return true
    }
}
