import Foundation

/// Tuya raw IR codes are base64 of little-endian UInt16 durations in microseconds:
/// mark, space, mark, space… always ending on a mark. Same format tinytuya and Redshift use.
enum IRPulses {
    static func base64(_ pulses: [Int]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(pulses.count * 2)
        for p in pulses {
            let v = UInt16(clamping: p)
            bytes.append(UInt8(v & 0xff))
            bytes.append(UInt8(v >> 8))
        }
        return Data(bytes).base64EncodedString()
    }

    static func pulses(_ code: String) -> [Int]? {
        var s = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some blasters report learned codes with a leading "1".
        if s.count % 4 == 1, s.hasPrefix("1") { s.removeFirst() }
        guard let d = Data(base64Encoded: s), !d.isEmpty, d.count % 2 == 0 else { return nil }
        let b = [UInt8](d)
        return stride(from: 0, to: b.count, by: 2).map { Int(b[$0]) | (Int(b[$0 + 1]) << 8) }
    }

    /// Cleans a learned code into plain base64 the blaster can replay.
    static func normalize(_ code: String) -> String? {
        guard let p = pulses(code), p.count >= 4 else { return nil }
        return base64(p)
    }
}

/// NEC: 9 ms mark, 4.5 ms space, then address, ~address, command, ~command, least significant bit first.
/// A bit is a 560 µs mark followed by a 560 µs (0) or 1690 µs (1) space. Vizio sound bars use address 0.
enum NEC {
    static func code(address: UInt8 = 0x00, command: UInt8) -> String {
        var p: [Int] = [9000, 4500]
        for byte in [address, ~address, command, ~command] {
            for i in 0..<8 {
                p.append(560)
                p.append((byte >> UInt8(i)) & 1 == 1 ? 1690 : 560)
            }
        }
        p.append(560)
        return IRPulses.base64(p)
    }
}

/// What the blaster speaks. tinytuya calls these control type 1 and 2.
enum IRFormat: String, Codable, CaseIterable, Identifiable {
    case classic, modern
    var id: String { rawValue }
    var title: String { self == .classic ? "Classic (DP 201/202)" : "Newer (DP 1–13)" }
}

enum IRCommand {
    static func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    static func send(_ code: String, _ format: IRFormat) -> [String: JSONValue] {
        switch format {
        case .classic:
            return ["201": .string(json(["control": "send_ir", "type": 0, "head": "", "key1": "1" + code]))]
        case .modern:
            return ["1": .string("study_key"), "13": .int(0), "7": .string(code)]
        }
    }

    static func mode(_ mode: String, _ format: IRFormat) -> [String: JSONValue] {
        switch format {
        case .classic: return ["201": .string(json(["control": mode]))]
        case .modern: return ["1": .string(mode)]
        }
    }

    static func study(_ f: IRFormat) -> [String: JSONValue] { mode("study", f) }
    static func studyExit(_ f: IRFormat) -> [String: JSONValue] { mode("study_exit", f) }

    /// A learned code in a status report, and which format it came in on.
    static func learned(in dps: [String: JSONValue]) -> (code: String, format: IRFormat)? {
        for (dp, f) in [("202", IRFormat.classic), ("2", IRFormat.modern)] {
            if let s = dps[dp]?.stringValue, s.count >= 8, let clean = IRPulses.normalize(s) {
                return (clean, f)
            }
        }
        return nil
    }

    static func hint(_ dps: [String: JSONValue]) -> IRFormat? {
        if dps["201"] != nil || dps["202"] != nil { return .classic }
        if dps["1"] != nil || dps["13"] != nil { return .modern }
        return nil
    }
}

// MARK: - Sound bar keys

enum IRGroup: String, CaseIterable, Identifiable {
    case main = "Power and volume"
    case inputs = "Inputs"
    case playback = "Playback"
    case levels = "Levels"
    case modes = "Sound modes"
    case features = "Features"
    case navigation = "Menu and navigation"
    case setup = "Setup"
    var id: String { rawValue }
}

struct IRKeyDef: Identifiable, Hashable {
    let id: String
    let label: String
    let symbol: String?
    let group: IRGroup
    /// NEC command on address 0. Nil when no code is known: learn it from the real remote.
    let nec: UInt8?

    var builtin: String? { nec.map { NEC.code(command: $0) } }
}

/// Vizio sound bar remote codes (NEC, address 0x00). From the Flipper-IRDB captures of the SB3651, V51 and
/// V51x remotes. Older bars use a few different codes; anything that doesn't work can be re-learned.
/// Key ids match Redshift's sound bar template so its learned codes import as they are.
enum IRKeys {
    static let all: [IRKeyDef] = [
        .init(id: "power", label: "Power", symbol: "power", group: .main, nec: 0x40),
        .init(id: "volUp", label: "Volume up", symbol: "plus", group: .main, nec: 0x41),
        .init(id: "volDown", label: "Volume down", symbol: "minus", group: .main, nec: 0x45),
        .init(id: "mute", label: "Mute", symbol: "speaker.slash.fill", group: .main, nec: 0x48),

        .init(id: "input", label: "Input (cycle)", symbol: "rectangle.portrait.and.arrow.forward", group: .inputs, nec: nil),
        .init(id: "bluetooth", label: "Bluetooth", symbol: "dot.radiowaves.left.and.right", group: .inputs, nec: 0x22),
        .init(id: "hdmiArc", label: "HDMI ARC", symbol: "tv", group: .inputs, nec: 0x9A),
        .init(id: "hdmiIn", label: "HDMI in", symbol: "cable.connector", group: .inputs, nec: 0xAB),
        .init(id: "optical", label: "Optical", symbol: "light.beacon.max", group: .inputs, nec: 0xC8),
        .init(id: "coax", label: "Coaxial", symbol: "cable.coaxial", group: .inputs, nec: 0xC9),
        .init(id: "aux", label: "AUX", symbol: "headphones", group: .inputs, nec: 0xB1),
        .init(id: "usb", label: "USB", symbol: "externaldrive", group: .inputs, nec: 0xA1),

        .init(id: "prev", label: "Previous", symbol: "backward.fill", group: .playback, nec: 0x8A),
        .init(id: "playPause", label: "Play/Pause", symbol: "playpause.fill", group: .playback, nec: 0x8E),
        .init(id: "next", label: "Next", symbol: "forward.fill", group: .playback, nec: 0x8B),

        .init(id: "bassUp", label: "Bass up", symbol: "plus", group: .levels, nec: 0x6B),
        .init(id: "bassDown", label: "Bass down", symbol: "minus", group: .levels, nec: 0x6A),
        .init(id: "trebleUp", label: "Treble up", symbol: "plus", group: .levels, nec: 0x69),
        .init(id: "trebleDown", label: "Treble down", symbol: "minus", group: .levels, nec: 0x68),
        .init(id: "subUp", label: "Subwoofer up", symbol: "plus", group: .levels, nec: 0x4D),
        .init(id: "subDown", label: "Subwoofer down", symbol: "minus", group: .levels, nec: 0x51),
        .init(id: "centerUp", label: "Center up", symbol: "plus", group: .levels, nec: 0x70),
        .init(id: "centerDown", label: "Center down", symbol: "minus", group: .levels, nec: 0x6E),
        .init(id: "dialogUp", label: "Dialogue up", symbol: "plus", group: .levels, nec: 0xDF),
        .init(id: "dialogDown", label: "Dialogue down", symbol: "minus", group: .levels, nec: 0xE0),
        .init(id: "surroundUp", label: "Surround up", symbol: "plus", group: .levels, nec: 0x6D),
        .init(id: "surroundDown", label: "Surround down", symbol: "minus", group: .levels, nec: 0x6C),
        .init(id: "heightUp", label: "Height up", symbol: "arrow.up.to.line", group: .levels, nec: nil),
        .init(id: "heightDown", label: "Height down", symbol: "arrow.down.to.line", group: .levels, nec: nil),

        .init(id: "eq", label: "Sound mode (cycle)", symbol: "slider.horizontal.3", group: .modes, nec: nil),
        .init(id: "eqMusic", label: "Music", symbol: "music.note", group: .modes, nec: 0x66),
        .init(id: "eqMovie", label: "Movie", symbol: "film", group: .modes, nec: 0x67),
        .init(id: "eqGame", label: "Game", symbol: "gamecontroller", group: .modes, nec: 0xE1),
        .init(id: "eqDirect", label: "Direct", symbol: "waveform", group: .modes, nec: 0x8C),

        .init(id: "nightOn", label: "Night mode on", symbol: "moon.fill", group: .features, nec: 0x61),
        .init(id: "nightOff", label: "Night mode off", symbol: "moon", group: .features, nec: 0x62),
        .init(id: "truVolOn", label: "TruVolume on", symbol: "speaker.wave.2.fill", group: .features, nec: 0x28),
        .init(id: "truVolOff", label: "TruVolume off", symbol: "speaker.wave.2", group: .features, nec: 0x42),
        .init(id: "vxOn", label: "Virtual:X on", symbol: "cube.fill", group: .features, nec: 0x85),
        .init(id: "vxOff", label: "Virtual:X off", symbol: "cube", group: .features, nec: 0xA3),
        .init(id: "surroundOn", label: "Surround on", symbol: "hifispeaker.2.fill", group: .features, nec: 0x23),
        .init(id: "surroundOff", label: "Surround off", symbol: "hifispeaker.2", group: .features, nec: 0x24),

        .init(id: "up", label: "Up", symbol: "chevron.up", group: .navigation, nec: nil),
        .init(id: "down", label: "Down", symbol: "chevron.down", group: .navigation, nec: nil),
        .init(id: "left", label: "Left", symbol: "chevron.left", group: .navigation, nec: nil),
        .init(id: "right", label: "Right", symbol: "chevron.right", group: .navigation, nec: nil),
        .init(id: "ok", label: "OK", symbol: "circle.circle", group: .navigation, nec: nil),
        .init(id: "back", label: "Back", symbol: "arrow.uturn.backward", group: .navigation, nec: nil),

        .init(id: "btPair", label: "Bluetooth pairing", symbol: "personalhotspot", group: .setup, nec: 0x6F),
        .init(id: "menu", label: "Menu", symbol: "line.3.horizontal", group: .navigation, nec: nil),
        .init(id: "info", label: "Info", symbol: "info.circle", group: .setup, nec: 0x1B),
        .init(id: "avDelayUp", label: "AV delay up", symbol: "plus", group: .setup, nec: 0xD6),
        .init(id: "avDelayDown", label: "AV delay down", symbol: "minus", group: .setup, nec: 0x71),
        .init(id: "ledOn", label: "Power LED on", symbol: "light.min", group: .setup, nec: 0x20),
        .init(id: "ledOff", label: "Power LED off", symbol: "light.max", group: .setup, nec: 0x21),
        .init(id: "speakerTest", label: "Speaker test", symbol: "speaker.badge.exclamationmark", group: .setup, nec: 0xAC),
    ]

    static func def(_ id: String) -> IRKeyDef? { all.first { $0.id == id } }

    /// The code that gets sent: learned beats built-in.
    static func code(_ id: String, learned: [String: String] = LearnedCodes.load()) -> String? {
        learned[id] ?? def(id)?.builtin
    }
}

/// Codes learned from the real remote, by key id. Shared with the widget.
enum LearnedCodes {
    static func load() -> [String: String] { AppGroup.read([String: String].self, "ircodes.json") ?? [:] }
    static func save(_ c: [String: String]) { AppGroup.write(c, "ircodes.json") }

    /// Redshift's backup is a list of remotes with keys; take the learned codes off its sound bar remote.
    static func fromRedshift(_ data: Data) -> [String: String]? {
        guard let remotes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var out: [String: String] = [:]
        let bars = remotes.filter { ($0["kind"] as? String) == "soundbar" }
        guard !bars.isEmpty else { return nil }
        for r in bars {
            for k in r["keys"] as? [[String: Any]] ?? [] {
                if let id = k["id"] as? String, let code = k["code"] as? String, let clean = IRPulses.normalize(code) {
                    out[id] = clean
                }
            }
        }
        return out
    }
}
