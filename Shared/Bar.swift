import Foundation
import WidgetKit

/// How commands reach the bar.
enum BarRoute: String, Codable, CaseIterable, Identifiable {
    /// Wi-Fi (SmartCast) first, IR through the blaster when the bar doesn't answer.
    case auto
    case wifi
    case ir
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Wi-Fi, then IR"
        case .wifi: return "Wi-Fi only"
        case .ir: return "IR only"
        }
    }
}

struct BarConfig: Codable, Equatable {
    var host: String = ""
    var port: Int?
    var auth: String?
    var name: String = "Sound bar"
    var model: String?
    var route: BarRoute = .auto
    /// Stable id this phone pairs with, if the bar ever asks for pairing.
    var deviceID: String = "subwave-" + UUID().uuidString.prefix(8).lowercased()

    var hasWiFi: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    static var stored: BarConfig {
        get { AppGroup.read(BarConfig.self, "bar.json") ?? BarConfig() }
        set { AppGroup.write(newValue, "bar.json") }
    }
}

/// Last known state, for the widget and for deciding what an IR power toggle will do.
struct BarState: Codable, Equatable {
    var power: Bool?
    var volume: Int?
    var muted: Bool?
    var input: String?
    var via: String?
    var updated: Date = .distantPast

    static var stored: BarState {
        get { AppGroup.read(BarState.self, "state.json") ?? BarState() }
        set { AppGroup.write(newValue, "state.json") }
    }
}

enum BarAction: Equatable {
    case power(Bool?)          // nil toggles
    case volumeUp(Int)
    case volumeDown(Int)
    case setVolume(Int)
    case mute(Bool?)           // nil toggles
    case input(String)         // a SmartCast input name or an IR key id
    case play, pause, playPause, next, previous
    case irKey(String)

    var label: String {
        switch self {
        case .power(let on): return on == nil ? "Power" : (on! ? "Power on" : "Power off")
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .setVolume(let v): return "Volume \(v)"
        case .mute: return "Mute"
        case .input(let n): return n
        case .play: return "Play"
        case .pause: return "Pause"
        case .playPause: return "Play/Pause"
        case .next: return "Next"
        case .previous: return "Previous"
        case .irKey(let k): return IRKeys.def(k)?.label ?? k
        }
    }
}

enum BarPath: String { case wifi = "Wi-Fi", ir = "IR" }

struct BarError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// The one place commands go through, from the app, the widget, Control Center and Siri.
enum Bar {
    @discardableResult
    static func perform(_ action: BarAction, cfg: BarConfig = .stored) async throws -> BarPath {
        var wifiError: Error?
        if cfg.route != .ir, let sc = SmartCast(cfg), wifiCan(action) {
            do {
                try await wifi(action, sc)
                note(action, .wifi)
                return .wifi
            } catch {
                wifiError = error
                if cfg.route == .wifi { throw error }
            }
        }
        if cfg.route != .wifi, let keys = irKeys(for: action), BlasterConfig.stored.isReady {
            for (i, k) in keys.enumerated() {
                guard let code = IRKeys.code(k) else {
                    throw BarError("No IR code for \(IRKeys.def(k)?.label ?? k) yet. Learn it in Subwave › IR remote.")
                }
                try await IRSender.shared.send(code)
                if i < keys.count - 1 { try? await Task.sleep(nanoseconds: 140_000_000) }
            }
            note(action, .ir)
            return .ir
        }
        if let wifiError { throw wifiError }
        if !cfg.hasWiFi && !BlasterConfig.stored.isReady {
            throw BarError("Set up the sound bar in Subwave first.")
        }
        throw BarError("\(action.label) needs \(cfg.hasWiFi ? "the IR blaster" : "the sound bar on Wi-Fi").")
    }

    private static func wifiCan(_ a: BarAction) -> Bool {
        switch a {
        case .next, .previous: return false
        // No play/pause toggle on Wi-Fi; IR has one, so prefer it when the blaster is set up.
        case .playPause: return !BlasterConfig.stored.isReady
        case .irKey(let k):
            return ["power", "volUp", "volDown", "mute"].contains(k) || inputName(forKey: k) != nil || SoundMenu.feature(k) != nil
        default: return true
        }
    }

    /// The SmartCast input word for a remote input key.
    static func inputName(forKey k: String) -> [String]? {
        switch k {
        case "hdmiArc": return ["arc", "earc"]
        case "hdmiIn": return ["hdmi"]
        case "optical": return ["optical", "optic"]
        case "bluetooth": return ["bluetooth", "bt"]
        case "aux": return ["aux"]
        case "usb": return ["usb"]
        case "coax": return ["coax", "digital"]
        default: return nil
        }
    }

    /// Turns an IR input key (or a loose name) into the exact input name the bar uses.
    static func resolveInput(_ n: String, _ sc: SmartCast) async throws -> String {
        guard let words = inputName(forKey: n) else { return n }
        let list = try await sc.inputs()
        func label(_ i: SCItem) -> String { (i.name + " " + (i.stringValue ?? "") + " " + i.cname).lowercased() }
        // "hdmi" must not grab the ARC input.
        if n == "hdmiIn", let hit = list.first(where: { label($0).contains("hdmi") && !label($0).contains("arc") }) {
            return hit.name
        }
        for w in words {
            if let hit = list.first(where: { label($0).contains(w) }) { return hit.name }
        }
        throw BarError("This bar has no \(IRKeys.def(n)?.label ?? n) input.")
    }

    private static func wifi(_ a: BarAction, _ sc: SmartCast) async throws {
        switch a {
        case .power(let on):
            try await sc.key(on == nil ? SCKey.powerToggle : (on! ? SCKey.powerOn : SCKey.powerOff))
        case .volumeUp(let n):
            for _ in 0..<max(1, n) { try await sc.key(SCKey.volUp) }
        case .volumeDown(let n):
            for _ in 0..<max(1, n) { try await sc.key(SCKey.volDown) }
        case .setVolume(let v):
            try await sc.setVolume(v)
        case .mute(let on):
            try await sc.key(on == nil ? SCKey.muteToggle : (on! ? SCKey.muteOn : SCKey.muteOff))
        case .input(let name):
            try await sc.setInput(try await resolveInput(name, sc))
        case .play, .playPause:
            try await sc.key(SCKey.play)
        case .pause:
            try await sc.key(SCKey.pause)
        case .irKey(let k):
            switch k {
            case "power": try await sc.key(SCKey.powerToggle)
            case "volUp": try await sc.key(SCKey.volUp)
            case "volDown": try await sc.key(SCKey.volDown)
            case "mute": try await sc.key(SCKey.muteToggle)
            default:
                if inputName(forKey: k) != nil {
                    try await sc.setInput(try await resolveInput(k, sc))
                } else {
                    try await SoundMenu.apply(k, sc)
                }
            }
        case .next, .previous:
            throw BarError("Not available on Wi-Fi.")
        }
    }

    /// Which remote buttons do the same thing. Nil when IR can't.
    static func irKeys(for a: BarAction) -> [String]? {
        switch a {
        case .power(let on):
            // The remote only has a toggle. Skip it if the bar is already where we want it.
            if let on, let known = BarState.stored.power, known == on,
               Date().timeIntervalSince(BarState.stored.updated) < 120 { return [] }
            return ["power"]
        case .volumeUp(let n): return Array(repeating: "volUp", count: max(1, min(n, 20)))
        case .volumeDown(let n): return Array(repeating: "volDown", count: max(1, min(n, 20)))
        case .mute: return ["mute"]
        case .input(let n):
            if IRKeys.def(n) != nil { return [n] }
            return inputKey(n).map { [$0] }
        case .play, .pause, .playPause: return ["playPause"]
        case .next: return ["next"]
        case .previous: return ["prev"]
        case .irKey(let k): return [k]
        case .setVolume: return nil
        }
    }

    /// Maps a SmartCast input name ("HDMI-ARC", "OPTICAL", "BT") to the remote's direct input key.
    static func inputKey(_ name: String) -> String? {
        let n = name.lowercased()
        if n.contains("arc") { return "hdmiArc" }
        if n.contains("optic") { return "optical" }
        if n.contains("blue") || n == "bt" { return "bluetooth" }
        if n.contains("aux") { return "aux" }
        if n.contains("usb") { return "usb" }
        if n.contains("coax") || n.contains("digital") { return "coax" }
        if n.contains("hdmi") { return "hdmiIn" }
        return nil
    }

    private static func note(_ a: BarAction, _ path: BarPath) {
        var s = BarState.stored
        switch a {
        case .power(let on):
            if let on { s.power = on } else if let p = s.power { s.power = !p }
        case .mute(let on):
            if let on { s.muted = on } else if let m = s.muted { s.muted = !m }
        case .setVolume(let v): s.volume = v
        case .volumeUp(let n): s.volume = s.volume.map { min(100, $0 + n) }
        case .volumeDown(let n): s.volume = s.volume.map { max(0, $0 - n) }
        case .input(let n): s.input = IRKeys.def(n)?.label ?? n
        case .irKey(let k):
            if k == "power", let p = s.power { s.power = !p }
            if k == "mute", let m = s.muted { s.muted = !m }
            if inputName(forKey: k) != nil { s.input = IRKeys.def(k)?.label }
        default: break
        }
        s.via = path.rawValue
        s.updated = .now
        BarState.stored = s
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Reads power, volume, mute and input over Wi-Fi.
    @discardableResult
    static func refresh(cfg: BarConfig = .stored) async -> BarState {
        var s = BarState.stored
        guard let sc = SmartCast(cfg, timeout: 3) else { return s }
        do {
            s.power = try await sc.power()
            if s.power == true {
                async let v = try? sc.volume()
                async let m = try? sc.muted()
                async let i = try? sc.currentInput()
                let (vol, mute, inp) = await (v, m, i)
                if let vol { s.volume = vol }
                if let mute { s.muted = mute }
                if let inp { s.input = inp }
            }
            s.via = BarPath.wifi.rawValue
            s.updated = .now
        } catch {
            // Deep standby drops off Wi-Fi: call it off.
            if (error as? SmartCastError)?.unreachable == true {
                s.power = false
                s.updated = .now
            }
        }
        BarState.stored = s
        return s
    }
}

/// Sends IR through the Tuya blaster. Keeps one connection for a little while, then lets go
/// so Smart Life, Redshift and the Afterglow bridge can still reach it (many blasters take one at a time).
actor IRSender {
    static let shared = IRSender()
    private var link: LocalLink?
    private var idle: Task<Void, Never>?
    private var listener: (@Sendable ([String: JSONValue]) -> Void)?
    /// While learning, the connection stays up.
    private var hold = false

    func send(_ code: String) async throws {
        let cfg = BlasterConfig.stored
        try await raw(IRCommand.send(code, cfg.format))
    }

    /// Any data points to the blaster (learn mode on/off). Reconnects once if the socket went stale.
    func raw(_ dps: [String: JSONValue]) async throws {
        let cfg = BlasterConfig.stored
        guard cfg.isReady else { throw BarError("Set up the IR blaster in Subwave first.") }
        do {
            let l = try await open(cfg)
            try await l.set(dps)
        } catch {
            await drop()
            let l = try await open(cfg)
            try await l.set(dps)
        }
        armIdle()
    }

    func query() async throws -> [String: JSONValue] {
        let l = try await open(BlasterConfig.stored)
        armIdle()
        return try await l.query()
    }

    /// Gets every data point the blaster reports (learned codes arrive this way).
    func listen(_ f: (@Sendable ([String: JSONValue]) -> Void)?) {
        listener = f
    }

    func setHold(_ on: Bool) {
        hold = on
        if on { idle?.cancel() } else { armIdle() }
    }

    func deliver(_ dps: [String: JSONValue]) {
        listener?(dps)
    }

    func drop() async {
        idle?.cancel()
        if let l = link { await l.close() }
        link = nil
    }

    /// Opens (or reuses) the link. Returns the protocol version it settled on.
    @discardableResult
    func connect() async throws -> Double {
        let l = try await open(BlasterConfig.stored)
        armIdle()
        return l.version
    }

    private func open(_ cfg: BlasterConfig) async throws -> LocalLink {
        if let l = link, await l.isOpen { return l }
        guard let devId = cfg.devId, let key = cfg.localKey, let host = cfg.host else {
            throw BarError("Set up the IR blaster in Subwave first.")
        }
        let onDPS: @Sendable ([String: JSONValue]) -> Void = { dps in Task { await IRSender.shared.deliver(dps) } }
        let onClose: @Sendable (String) -> Void = { _ in Task { await IRSender.shared.closed() } }
        if let v = cfg.version {
            let l = LocalLink(devId: devId, host: host, localKey: key, version: v, onDPS: onDPS, onClose: onClose)
            do {
                try await l.open()
                link = l
                return l
            } catch {
                await l.close()
            }
        }
        let r = try await LocalLink.detect(devId: devId, host: host, localKey: key, knownDPs: [],
                                           onDPS: onDPS, onClose: onClose)
        var c = BlasterConfig.stored
        c.version = r.0.version
        BlasterConfig.stored = c
        link = r.0
        if !r.1.isEmpty { listener?(r.1) }
        return r.0
    }

    private func closed() {
        link = nil
    }

    private func armIdle() {
        idle?.cancel()
        guard !hold else { return }
        idle = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self.drop()
        }
    }
}

// MARK: - Sony TV (same as Afterglow), for "sound bar off if the TV is off"

struct TVConfig: Codable, Equatable {
    var host: String = ""
    var psk: String = ""

    var isSet: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    static var stored: TVConfig {
        get { AppGroup.read(TVConfig.self, "tv.json") ?? TVConfig() }
        set { AppGroup.write(newValue, "tv.json") }
    }
}

enum TV {
    /// True on, false standby or off the network.
    static func isOn(_ cfg: TVConfig = .stored, timeout: Double = 2.5) async -> Bool {
        let host = cfg.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let url = URL(string: "http://\(host)/sony/system") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.psk.isEmpty { req.setValue(cfg.psk, forHTTPHeaderField: "X-Auth-PSK") }
        req.httpBody = Data(#"{"method":"getPowerStatus","id":50,"params":[],"version":"1.0"}"#.utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let result = obj["result"] as? [[String: Any]], let status = result.first?["status"] as? String {
            return status == "active"
        }
        return obj["error"] != nil
    }
}
