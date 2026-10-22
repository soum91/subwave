import Foundation

/// Maps the remote's feature buttons (sound modes, night mode, bass up…) onto whatever the bar calls those
/// settings in its SmartCast menu, so they work over Wi-Fi too. Menu names differ between models and firmware,
/// so this matches by name rather than by fixed paths. Anything it can't find falls back to IR.
enum SoundMenu {
    enum Op {
        case choose([String])          // pick a list choice containing one of these words
        case toggle(Bool)              // On/Off list
        case step(Int)                 // slider +/-
    }

    struct Feature {
        let match: [String]            // words in the setting's name or cname
        let avoid: [String]
        let op: Op
    }

    static func feature(_ key: String) -> Feature? {
        switch key {
        case "eqMusic": return Feature(match: ["eq", "sound mode", "listening", "preset"], avoid: [], op: .choose(["music"]))
        case "eqMovie": return Feature(match: ["eq", "sound mode", "listening", "preset"], avoid: [], op: .choose(["movie"]))
        case "eqGame": return Feature(match: ["eq", "sound mode", "listening", "preset"], avoid: [], op: .choose(["game"]))
        case "eqDirect": return Feature(match: ["eq", "sound mode", "listening", "preset"], avoid: [], op: .choose(["direct", "flat"]))
        case "nightOn": return Feature(match: ["night"], avoid: [], op: .toggle(true))
        case "nightOff": return Feature(match: ["night"], avoid: [], op: .toggle(false))
        case "truVolOn": return Feature(match: ["truvolume", "tru volume", "volume leveler", "leveler"], avoid: [], op: .toggle(true))
        case "truVolOff": return Feature(match: ["truvolume", "tru volume", "volume leveler", "leveler"], avoid: [], op: .toggle(false))
        case "vxOn": return Feature(match: ["virtual"], avoid: [], op: .toggle(true))
        case "vxOff": return Feature(match: ["virtual"], avoid: [], op: .toggle(false))
        case "surroundOn": return Feature(match: ["surround"], avoid: ["level", "volume"], op: .toggle(true))
        case "surroundOff": return Feature(match: ["surround"], avoid: ["level", "volume"], op: .toggle(false))
        case "surroundDual": return Feature(match: ["surround"], avoid: ["level", "volume"], op: .choose(["dual"]))
        case "bassUp": return Feature(match: ["bass"], avoid: [], op: .step(1))
        case "bassDown": return Feature(match: ["bass"], avoid: [], op: .step(-1))
        case "trebleUp": return Feature(match: ["treble"], avoid: [], op: .step(1))
        case "trebleDown": return Feature(match: ["treble"], avoid: [], op: .step(-1))
        case "subUp": return Feature(match: ["subwoofer", "sub level", "sub"], avoid: [], op: .step(1))
        case "subDown": return Feature(match: ["subwoofer", "sub level", "sub"], avoid: [], op: .step(-1))
        case "centerUp": return Feature(match: ["center"], avoid: [], op: .step(1))
        case "centerDown": return Feature(match: ["center"], avoid: [], op: .step(-1))
        case "dialogUp": return Feature(match: ["dialog", "dialogue", "speech"], avoid: [], op: .step(1))
        case "dialogDown": return Feature(match: ["dialog", "dialogue", "speech"], avoid: [], op: .step(-1))
        case "surroundUp": return Feature(match: ["surround"], avoid: [], op: .step(1))
        case "surroundDown": return Feature(match: ["surround"], avoid: [], op: .step(-1))
        case "heightUp": return Feature(match: ["height"], avoid: [], op: .step(1))
        case "heightDown": return Feature(match: ["height"], avoid: [], op: .step(-1))
        case "avDelayUp": return Feature(match: ["delay", "lip sync"], avoid: [], op: .step(1))
        case "avDelayDown": return Feature(match: ["delay", "lip sync"], avoid: [], op: .step(-1))
        default: return nil
        }
    }

    /// Every adjustable item in the audio menus (one level of submenus deep), with ranges filled in.
    static func audioItems(_ sc: SmartCast) async throws -> [SCItem] {
        let root = try await sc.fullMenu(SmartCast.settingsRoot)
        var out: [SCItem] = []
        for it in root where !it.hidden {
            if it.kind == .menu {
                let lower = it.cname.lowercased()
                // Inputs, network and system stuff aren't sound settings.
                if ["input", "network", "system", "admin", "cast", "timers"].contains(where: { lower.contains($0) }) { continue }
                if let sub = try? await sc.fullMenu(it.path) { out += sub.filter { !$0.hidden && $0.kind != .menu } }
            } else {
                out.append(it)
            }
        }
        return out
    }

    static func find(_ f: Feature, in items: [SCItem]) -> SCItem? {
        func fits(_ it: SCItem) -> Bool {
            let n = (it.name + " " + it.cname).lowercased()
            guard f.match.contains(where: { n.contains($0) }), !f.avoid.contains(where: { n.contains($0) }) else { return false }
            switch f.op {
            case .choose(let words): return it.choices.contains { c in words.contains { c.lowercased().contains($0) } }
            case .toggle:
                // Some settings have more than on/off (Surround Sound: On / Off / Dual).
                let c = Set(it.choices.map { $0.lowercased() })
                return (it.kind == .list || it.kind == .xlist) && c.contains("on") && c.contains("off")
            case .step: return it.kind == .slider || it.kind == .value
            }
        }
        // Earlier match words are more specific: prefer them.
        for w in f.match {
            if let it = items.first(where: { fits($0) && ($0.name + " " + $0.cname).lowercased().contains(w) && !$0.readOnly }) { return it }
        }
        return nil
    }

    /// The bar's own list setting behind an on/off feature button, with every choice it really has.
    static func listItem(for key: String, in items: [SCItem]) -> SCItem? {
        guard let f = feature(key) else { return nil }
        return items.first { it in
            let n = (it.name + " " + it.cname).lowercased()
            return (it.kind == .list || it.kind == .xlist) && it.choices.count >= 2 && !it.readOnly && !it.hidden
                && f.match.contains(where: { n.contains($0) }) && !f.avoid.contains(where: { n.contains($0) })
        }
    }

    /// Runs a feature button over Wi-Fi. Throws if the bar has no matching setting.
    static func apply(_ key: String, _ sc: SmartCast) async throws {
        guard let f = feature(key) else { throw BarError("Not a Wi-Fi setting.") }
        let items = try await audioItems(sc)
        guard let it = find(f, in: items) else { throw BarError("This bar has no \(IRKeys.def(key)?.label ?? key) setting.") }
        switch f.op {
        case .choose(let words):
            guard let c = it.choices.first(where: { c in words.contains { c.lowercased().contains($0) } }) else { return }
            try await sc.set(it.path, c)
        case .toggle(let on):
            let c = it.choices.first { $0.lowercased() == (on ? "on" : "off") } ?? (on ? "On" : "Off")
            try await sc.set(it.path, c)
        case .step(let d):
            let now = it.intValue ?? it.center ?? 0
            let v = Swift.max(it.min ?? -100, Swift.min(it.max ?? 100, now + d))
            try await sc.set(it.path, v)
        }
    }
}

// MARK: - Presets

/// A saved setup, like Afterglow scenes: power on, an input, a volume and any sound settings.
struct BarPreset: Codable, Identifiable, Equatable, Hashable {
    struct Setting: Codable, Equatable, Hashable {
        var path: String
        var name: String
        var value: JSONValue
    }

    var id = UUID().uuidString
    var name: String
    var icon: String
    var powerOn = true
    var input: String?
    var volume: Int?
    /// Exact SmartCast settings (captured from the bar). Used when the bar is on Wi-Fi.
    var settings: [Setting] = []
    /// Remote buttons to press after (sound mode, night mode…). Over Wi-Fi when the bar has a matching setting.
    var keys: [String] = []

    var summary: String {
        var parts: [String] = []
        if let input { parts.append(IRKeys.def(input)?.label ?? input) }
        if let volume { parts.append("vol \(volume)") }
        parts += keys.compactMap { IRKeys.def($0)?.label }
        if !settings.isEmpty { parts.append("\(settings.count) setting\(settings.count == 1 ? "" : "s")") }
        if !powerOn { return "Power off" }
        return parts.isEmpty ? "Power on" : parts.joined(separator: " · ")
    }

    static let defaults: [BarPreset] = [
        BarPreset(name: "TV", icon: "tv", input: "hdmiArc", keys: ["eqMovie", "nightOff"]),
        BarPreset(name: "Music", icon: "music.note", keys: ["eqMusic", "nightOff"]),
        BarPreset(name: "Late night", icon: "moon.stars.fill", volume: 14, keys: ["nightOn", "dialogUp"]),
        BarPreset(name: "Off", icon: "power", powerOn: false),
    ]
}

enum PresetStore {
    static func load() -> [BarPreset] { AppGroup.read([BarPreset].self, "presets.json") ?? BarPreset.defaults }
    static func save(_ p: [BarPreset]) { AppGroup.write(p, "presets.json") }
}

enum Presets {
    static func run(_ p: BarPreset) async throws {
        guard p.powerOn else {
            try await Bar.perform(.power(false))
            return
        }
        let cfg = BarConfig.stored
        let wasOff = BarState.stored.power != true
        try await Bar.perform(.power(true))
        // A bar coming out of standby ignores commands for a moment.
        if wasOff { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        var failures: [String] = []
        if let input = p.input {
            do { try await Bar.perform(.input(input)) } catch { failures.append(error.localizedDescription) }
        }
        if let v = p.volume {
            do { try await Bar.perform(.setVolume(v)) } catch {
                // No absolute volume on IR: skip quietly unless that was the whole point.
                if p.settings.isEmpty && p.keys.isEmpty { failures.append(error.localizedDescription) }
            }
        }
        if !p.settings.isEmpty, cfg.route != .ir, let sc = SmartCast(cfg) {
            for s in p.settings {
                do { try await sc.set(s.path, s.value.any) } catch { failures.append("\(s.name): \(error.localizedDescription)") }
            }
        }
        for k in p.keys {
            do { try await Bar.perform(.irKey(k)) } catch { failures.append(error.localizedDescription) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if failures.count > 0 && failures.count >= 1 + p.keys.count + p.settings.count {
            throw BarError(failures.first ?? "That preset didn't go through.")
        }
    }

    /// Reads what the bar is doing now, for "capture current" in the preset editor.
    static func capture(into p: BarPreset) async throws -> BarPreset {
        guard let sc = SmartCast(BarConfig.stored) else { throw BarError("Capturing needs the sound bar on Wi-Fi.") }
        var out = p
        out.powerOn = true
        out.input = try? await sc.currentInput()
        out.volume = try? await sc.volume()
        let items = try await SoundMenu.audioItems(sc)
        out.settings = items.compactMap { it in
            guard !it.readOnly, it.kind == .slider || it.kind == .list || it.kind == .xlist || it.kind == .value else { return nil }
            let n = it.cname.lowercased()
            // Volume and mute are handled on their own; reset buttons and names aren't settings.
            if n == "volume" || n == "mute" || n.contains("reset") || n.contains("name") { return nil }
            if case .null = it.value { return nil }
            return BarPreset.Setting(path: it.path, name: it.name, value: it.value)
        }
        out.keys = []
        return out
    }
}
