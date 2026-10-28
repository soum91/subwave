import Foundation

/// The TV rule for the sound bar. Stored here and pushed to the Afterglow ESP32 bridge,
/// which runs it (it's always on; the phone isn't).
struct BarAutomations: Codable, Equatable {
    var offEnabled = true
    /// Seconds after the TV goes off.
    var offDelay = 5
    var offWindow = false
    var offFrom = 19 * 60
    var offTo = 6 * 60
    /// IR-only bars: the remote's power button is a toggle, so only use it when the bar doesn't follow the TV
    /// over HDMI-CEC by itself (otherwise it would turn the bar back on).
    var irToggleWhenOff = false

    var onEnabled = false
    var onWindow = false
    var onFrom = 17 * 60
    var onTo = 1 * 60

    static var stored: BarAutomations {
        get { AppGroup.read(BarAutomations.self, "automations.json") ?? BarAutomations() }
        set { AppGroup.write(newValue, "automations.json") }
    }
}

struct BridgeConfig: Codable, Equatable {
    var host: String = ""
    var port: Int = 8080
    var token: String = ""
    var lastPush: Date?

    var isSet: Bool { !host.isEmpty }
    var isPaired: Bool { isSet && !token.isEmpty }

    static var stored: BridgeConfig {
        get { AppGroup.read(BridgeConfig.self, "bridge.json") ?? BridgeConfig() }
        set { AppGroup.write(newValue, "bridge.json") }
    }
}

struct BridgeInfo: Decodable {
    struct T: Decodable { var state: String?; var host: String? }
    struct B: Decodable {
        var claimed: Bool?
        var state: String?
        var follow: Bool?
        var configured: Bool?
        var events: [String]?
    }
    var app: String
    var version: String?
    var tv: T?
    var bar: B?
    var events: [String]?
    var uptime: Int?
    var time: String?
}

enum BridgeAPI {
    static func url(_ cfg: BridgeConfig, _ path: String) -> URL? {
        URL(string: "http://\(cfg.host):\(cfg.port)\(path)")
    }

    static func info(_ cfg: BridgeConfig = .stored) async throws -> BridgeInfo {
        guard let u = url(cfg, "/api/info") else { throw BarError("Bad bridge address.") }
        var req = URLRequest(url: u)
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        let info = try JSONDecoder().decode(BridgeInfo.self, from: data)
        guard info.app == "afterglow-bridge" else { throw BarError("That isn't a Keystone Bridge.") }
        guard info.bar != nil else {
            throw BarError("This bridge's firmware is too old for the sound bar. Update it from the Keystone app (Bridge › Firmware).")
        }
        return info
    }

    /// Subwave gets its own token, separate from Afterglow's. Reset from Keystone › Bridge › Pairings.
    static func claim(_ cfg: BridgeConfig) async throws -> String {
        guard let u = url(cfg, "/api/bar/claim") else { throw BarError("Bad bridge address.") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 409 {
            throw BarError("The bridge's sound bar side already belongs to another phone. Type @B in its serial console to reset it.")
        }
        if code == 404 { throw BarError("This bridge's firmware is too old for the sound bar. Update it first.") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let t = obj["token"] as? String else {
            throw BarError("The bridge didn't hand out a token.")
        }
        return t
    }

    private static func post(_ path: String, _ body: [String: Any], _ cfg: BridgeConfig) async throws -> [String: Any] {
        guard let u = url(cfg, path) else { throw BarError("Bad bridge address.") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.token, forHTTPHeaderField: "X-Subwave-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw BarError("The bridge rejected this phone's token. Reset it with @B and pair again.") }
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BarError("Bridge said: \(String(decoding: data, as: UTF8.self))")
        }
        return obj
    }

    static func push(_ body: [String: Any], _ cfg: BridgeConfig) async throws -> Bool {
        let obj = try await post("/api/bar/config", body, cfg)
        return obj["restart"] as? Bool ?? false
    }

    /// Has the bridge switch the bar, to check it can reach it.
    static func test(on: Bool, _ cfg: BridgeConfig = .stored) async throws -> String {
        let obj = try await post("/api/bar/power", ["on": on], cfg)
        return obj["via"] as? String ?? "?"
    }

    /// Everything the bridge needs, with IR already in the blaster's data point form.
    static func config(bar: BarConfig, blaster: BlasterConfig, auto: BarAutomations, tv: TVConfig) -> [String: Any] {
        var b: [String: Any] = ["name": bar.name, "ip": bar.host, "port": bar.port ?? 7345, "route": bar.route.rawValue]
        if let a = bar.auth, !a.isEmpty { b["auth"] = a }
        var body: [String: Any] = [
            "utcOffset": TimeZone.current.secondsFromGMT(),
            "bar": b,
            "tv": ["ip": tv.host, "psk": tv.psk],
            "off": ["enabled": auto.offEnabled, "delay": auto.offDelay, "window": auto.offWindow,
                    "from": auto.offFrom, "to": auto.offTo, "irToggle": auto.irToggleWhenOff],
            "on": ["enabled": auto.onEnabled, "window": auto.onWindow, "from": auto.onFrom, "to": auto.onTo],
        ]
        if blaster.isReady, let id = blaster.devId, let key = blaster.localKey, let ip = blaster.host,
           let power = IRKeys.code("power") {
            let send = IRCommand.send(power, blaster.format).mapValues { $0.any }
            body["blaster"] = ["id": id, "key": key, "ip": ip, "ver": blaster.version ?? 3.3, "power": send]
        }
        return body
    }
}

enum BridgeSync {
    private static let hashKey = "bridge.lastConfig"

    static func currentConfig() -> [String: Any] {
        BridgeAPI.config(bar: .stored, blaster: .stored, auto: .stored, tv: .stored)
    }

    static func fingerprint(_ body: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Sends the config if anything changed since the last push.
    @discardableResult
    static func pushIfChanged(force: Bool = false) async -> String? {
        var cfg = BridgeConfig.stored
        guard cfg.isPaired else { return nil }
        let body = currentConfig()
        let fp = fingerprint(body)
        if !force, UserDefaults.standard.string(forKey: hashKey) == fp { return nil }
        do {
            let restart = try await BridgeAPI.push(body, cfg)
            UserDefaults.standard.set(fp, forKey: hashKey)
            cfg.lastPush = .now
            BridgeConfig.stored = cfg
            return restart ? "Sent. The bridge is restarting to add the sound bar to Apple Home (about 20 s)." : "Sent to the bridge."
        } catch {
            return "Couldn't reach the bridge: \(error.localizedDescription)"
        }
    }
}
