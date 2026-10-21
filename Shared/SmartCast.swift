import Foundation

/// Vizio's SmartCast REST API, the thing the Vizio app uses underneath. HTTPS with a self-signed
/// certificate on port 7345 (older firmware 9000). Sound bars don't need a pairing token for it.
/// Endpoints and key codes from pyvizio (what Home Assistant's Vizio integration runs on).

struct SmartCastError: LocalizedError {
    let message: String
    var unreachable = false
    init(_ m: String, unreachable: Bool = false) { message = m; self.unreachable = unreachable }
    var errorDescription: String? { message }
}

/// One entry in a SmartCast settings menu.
struct SCItem: Identifiable, Hashable {
    enum Kind: Hashable { case menu, slider, list, value, xlist, action, other(String) }

    var hash: Int?
    var cname: String
    var name: String
    var kind: Kind
    var value: JSONValue
    var min: Int?
    var max: Int?
    var center: Int?
    var choices: [String]
    var readOnly: Bool
    var hidden: Bool
    /// Path of the menu this item lives in, without the item's own cname.
    var parent: String

    var id: String { parent + "/" + cname }
    var path: String { parent + "/" + cname }
    var intValue: Int? { value.doubleValue.map { Int($0) } }
    var stringValue: String? {
        if case .string(let s) = value { return s }
        return value.stringValue
    }
    /// On/Off style lists the app can show as a switch.
    var isToggle: Bool {
        guard kind == .list || kind == .xlist else { return false }
        let set = Set(choices.map { $0.lowercased() })
        return set == ["on", "off"]
    }

    static func kind(_ type: String) -> Kind {
        switch type.lowercased() {
        case "t_menu_v1", "t_audio_menu_v1": return .menu
        case "t_value_abs_v1": return .slider
        case "t_list_v1": return .list
        case "t_value_v1": return .value
        case "t_list_x_v1": return .xlist
        case "t_action_v1": return .action
        default: return .other(type)
        }
    }
}

/// Key codes: (codeset, code).
enum SCKey {
    static let pause = (2, 2), play = (2, 3)
    static let volDown = (5, 0), volUp = (5, 1), muteOff = (5, 2), muteOn = (5, 3), muteToggle = (5, 4)
    static let inputNext = (7, 1)
    static let powerOff = (11, 0), powerOn = (11, 1), powerToggle = (11, 2)
}

/// Accepts the bar's self-signed certificate, and only for the bar's own address.
final class SmartCastTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = SmartCastTrust()
    lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 8
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           Self.isLocal(host), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Private IPv4 ranges and .local names only.
    static func isLocal(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }
}

struct SmartCast: Sendable {
    var host: String
    var port: Int
    var auth: String?
    var timeout: Double = 3.5

    static let ports = [7345, 9000]
    static let settingsRoot = "/menu_native/dynamic/audio_settings"
    static let optionsRoot = "/menu_native/static/audio_settings"

    init(host: String, port: Int = 7345, auth: String? = nil, timeout: Double = 3.5) {
        self.host = host
        self.port = port
        self.auth = auth
        self.timeout = timeout
    }

    init?(_ cfg: BarConfig, timeout: Double = 3.5) {
        guard cfg.hasWiFi else { return nil }
        self.init(host: cfg.host, port: cfg.port ?? 7345, auth: cfg.auth, timeout: timeout)
    }

    // MARK: Plumbing

    private func url(_ path: String) -> URL? { URL(string: "https://\(host):\(port)\(path)") }

    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let u = url(path) else { throw SmartCastError("Bad sound bar address.") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let auth, !auth.isEmpty { req.setValue(auth, forHTTPHeaderField: "AUTH") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await SmartCastTrust.shared.session.data(for: req)
        } catch {
            throw SmartCastError("The sound bar didn't answer on Wi-Fi.", unreachable: true)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartCastError("The sound bar sent something odd (HTTP \(code)).")
        }
        let status = Self.ci(obj, "status") as? [String: Any]
        let result = (status.flatMap { Self.ci($0, "result") } as? String ?? "").lowercased()
        if result != "success" {
            let detail = status.flatMap { Self.ci($0, "detail") } as? String ?? result
            if result.contains("pair") || result.contains("blocked") || code == 403 {
                throw SmartCastError("The sound bar wants this phone paired first (Settings › Sound bar › Pair).")
            }
            throw SmartCastError("Sound bar said: \(detail.isEmpty ? "HTTP \(code)" : detail)")
        }
        return obj
    }

    /// Case-insensitive dictionary lookup. SmartCast answers in SHOUTING_CASE, mostly.
    static func ci(_ d: [String: Any], _ key: String) -> Any? {
        if let v = d[key] { return v }
        if let v = d[key.uppercased()] { return v }
        let k = key.lowercased()
        return d.first { $0.key.lowercased() == k }?.value
    }

    private func items(_ obj: [String: Any]) -> [[String: Any]] {
        Self.ci(obj, "items") as? [[String: Any]] ?? []
    }

    private func parse(_ raw: [String: Any], parent: String) -> SCItem {
        func int(_ k: String) -> Int? {
            if let n = Self.ci(raw, k) as? NSNumber { return n.intValue }
            if let s = Self.ci(raw, k) as? String { return Int(s) }
            return nil
        }
        func flag(_ k: String) -> Bool {
            if let b = Self.ci(raw, k) as? Bool { return b }
            if let s = Self.ci(raw, k) as? String { return s.lowercased() == "true" }
            return false
        }
        let type = Self.ci(raw, "type") as? String ?? ""
        let value = Self.ci(raw, "value")
        // Inputs report {NAME, METADATA} as their value.
        let v: JSONValue
        if let dict = value as? [String: Any], let n = Self.ci(dict, "name") as? String { v = .string(n) } else { v = .from(value) }
        return SCItem(hash: int("hashval"),
                      cname: Self.ci(raw, "cname") as? String ?? "",
                      name: Self.ci(raw, "name") as? String ?? (Self.ci(raw, "cname") as? String ?? ""),
                      kind: SCItem.kind(type),
                      value: v,
                      min: int("minimum"), max: int("maximum"), center: int("center"),
                      choices: (Self.ci(raw, "elements") as? [Any] ?? []).compactMap { $0 as? String },
                      readOnly: flag("readonly"),
                      hidden: flag("hidden"),
                      parent: parent)
    }

    // MARK: Device

    /// Which port answers. Nil if neither does.
    static func findPort(host: String, auth: String? = nil, preferred: Int? = nil) async -> Int? {
        var order = ports
        if let p = preferred { order.removeAll { $0 == p }; order.insert(p, at: 0) }
        for p in order {
            let sc = SmartCast(host: host, port: p, auth: auth, timeout: 2.5)
            if (try? await sc.power()) != nil { return p }
        }
        return nil
    }

    func power() async throws -> Bool {
        let obj = try await request("GET", "/state/device/power_mode")
        guard let first = items(obj).first, let v = Self.ci(first, "value") else { return false }
        return JSONValue.from(v).boolValue ?? false
    }

    func deviceInfo() async throws -> (name: String?, model: String?) {
        let obj = try await request("GET", "/state/device/deviceinfo")
        guard let first = items(obj).first, let value = Self.ci(first, "value") as? [String: Any] else { return (nil, nil) }
        let name = Self.ci(value, "name") as? String
        let model = (Self.ci(value, "model_name") as? String)
            ?? ((Self.ci(value, "system_info") as? [String: Any]).flatMap { Self.ci($0, "model_name") } as? String)
        return (name, model)
    }

    func key(_ k: (Int, Int), action: String = "KEYPRESS") async throws {
        try await request("PUT", "/key_command/", body: ["KEYLIST": [["CODESET": k.0, "CODE": k.1, "ACTION": action]]])
    }

    // MARK: Menus

    func menu(_ path: String = SmartCast.settingsRoot) async throws -> [SCItem] {
        let obj = try await request("GET", path)
        return items(obj).map { parse($0, parent: path) }.filter { !$0.cname.isEmpty }
    }

    /// Slider ranges and list choices for a menu live in the static tree, same path shape.
    func options(for menuPath: String) async throws -> [String: SCItem] {
        let staticPath = menuPath.replacingOccurrences(of: "/menu_native/dynamic/", with: "/menu_native/static/")
        let obj = try await request("GET", staticPath)
        var out: [String: SCItem] = [:]
        for raw in items(obj) {
            let it = parse(raw, parent: staticPath)
            out[it.cname] = it
        }
        return out
    }

    /// A menu with ranges and choices filled in from the static tree.
    func fullMenu(_ path: String) async throws -> [SCItem] {
        var list = try await menu(path)
        if let opts = try? await options(for: path) {
            for i in list.indices {
                guard let o = opts[list[i].cname] else { continue }
                list[i].min = list[i].min ?? o.min
                list[i].max = list[i].max ?? o.max
                list[i].center = list[i].center ?? o.center
                if list[i].choices.isEmpty { list[i].choices = o.choices }
            }
        }
        return list
    }

    /// Reads one item fresh, so its hash is current.
    func item(_ path: String) async throws -> SCItem {
        guard let slash = path.lastIndex(of: "/") else { throw SmartCastError("Bad setting path.") }
        let parent = String(path[..<slash])
        let cname = String(path[path.index(after: slash)...])
        let obj = try await request("GET", path)
        guard let raw = items(obj).first(where: { (Self.ci($0, "cname") as? String) == cname }) ?? items(obj).first else {
            throw SmartCastError("The sound bar doesn't have \(cname).")
        }
        return parse(raw, parent: parent)
    }

    func set(_ path: String, _ value: Any) async throws {
        let it = try await item(path)
        guard let hash = it.hash else { throw SmartCastError("The sound bar didn't give a handle for \(it.name).") }
        try await request("PUT", path, body: ["REQUEST": "MODIFY", "HASHVAL": hash, "VALUE": value])
    }

    func action(_ path: String) async throws {
        let it = try await item(path)
        guard let hash = it.hash else { throw SmartCastError("The sound bar didn't give a handle for \(it.name).") }
        try await request("PUT", path, body: ["REQUEST": "ACTION", "HASHVAL": hash])
    }

    // MARK: Audio shortcuts

    static let audioPath = settingsRoot + "/audio"
    static let volumePath = audioPath + "/volume"
    static let mutePath = audioPath + "/mute"
    static let inputPath = settingsRoot + "/input"
    static let currentInputPath = inputPath + "/current_input"

    func volume() async throws -> Int? { try await item(Self.volumePath).intValue }
    func setVolume(_ v: Int) async throws { try await set(Self.volumePath, max(0, min(100, v))) }

    func muted() async throws -> Bool? {
        (try await item(Self.mutePath).stringValue?.lowercased()).map { $0 == "on" }
    }

    // MARK: Inputs

    func inputs() async throws -> [SCItem] {
        try await menu(Self.inputPath).filter { $0.cname != "current_input" && !$0.hidden }
    }

    func currentInput() async throws -> String? {
        try await item(Self.currentInputPath).stringValue
    }

    func setInput(_ name: String) async throws {
        try await set(Self.currentInputPath, name)
    }

    // MARK: Pairing (sound bars normally skip this; some firmware asks)

    func beginPair(deviceID: String) async throws -> (challenge: Int, token: Int) {
        let obj = try await request("PUT", "/pairing/start", body: ["DEVICE_ID": deviceID, "DEVICE_NAME": "Subwave"])
        let item = Self.ci(obj, "item") as? [String: Any] ?? [:]
        let ch = (Self.ci(item, "challenge_type") as? NSNumber)?.intValue ?? 1
        let tok = (Self.ci(item, "pairing_req_token") as? NSNumber)?.intValue ?? 0
        return (ch, tok)
    }

    func finishPair(deviceID: String, challenge: Int, token: Int, pin: String) async throws -> String {
        let obj = try await request("PUT", "/pairing/pair", body: ["DEVICE_ID": deviceID, "CHALLENGE_TYPE": challenge,
                                                                  "PAIRING_REQ_TOKEN": token, "RESPONSE_VALUE": pin])
        let item = Self.ci(obj, "item") as? [String: Any] ?? [:]
        guard let t = Self.ci(item, "auth_token") as? String else { throw SmartCastError("The bar didn't hand out a token.") }
        return t
    }
}
