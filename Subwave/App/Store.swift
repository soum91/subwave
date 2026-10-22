import SwiftUI
import UIKit
import WidgetKit
import AVFoundation

enum LinkState: Equatable {
    case off, searching(String), connecting, connected(Double), failed(String)

    var text: String {
        switch self {
        case .off: return "Not connected"
        case .searching(let s): return s
        case .connecting: return "Connecting…"
        case .connected(let v): return "Connected (Tuya \(String(format: "%.1f", v)))"
        case .failed(let e): return e
        }
    }
    var isConnected: Bool { if case .connected = self { return true } else { return false } }
    var isBusy: Bool {
        switch self {
        case .searching, .connecting: return true
        default: return false
        }
    }
}

struct LearnSession: Identifiable, Equatable {
    enum Phase: Equatable { case starting, waiting, captured(Int), failed(String) }
    let id = UUID()
    var keyID: String
    var label: String
    var phase: Phase = .starting
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // Sound bar
    @Published var bar = BarConfig.stored { didSet { if bar != oldValue { BarConfig.stored = bar } } }
    @Published var state = BarState.stored
    @Published var inputs: [SCItem] = []
    /// The bar's sound settings, so the home screen shows real choices (Surround: On / Off / Dual).
    @Published var soundItems: [SCItem] = []
    @Published var wifiReachable: Bool?
    @Published var lastPath: BarPath?
    @Published var volumeDraft: Double?
    @Published var pairing: (challenge: Int, token: Int)?

    // Extras
    @Published var presets = PresetStore.load() { didSet { if presets != oldValue { PresetStore.save(presets) } } }
    @Published var tv = TVConfig.stored { didSet { if tv != oldValue { TVConfig.stored = tv } } }
    @Published var tvOn: Bool?
    @Published var auto = BarAutomations.stored { didSet { if auto != oldValue { BarAutomations.stored = auto } } }
    @Published var bridge = BridgeConfig.stored { didSet { if bridge != oldValue { BridgeConfig.stored = bridge } } }
    @Published var bridgeInfo: BridgeInfo?

    // IR blaster (same one Redshift uses)
    @Published var blaster = BlasterConfig.stored { didSet { if blaster != oldValue { BlasterConfig.stored = blaster } } }
    @Published var blasterState: LinkState = .off
    /// What each device on the Wi-Fi said during the last search, for when it goes wrong.
    @Published var blasterLog: [String] = []
    @Published var codes = LearnedCodes.load() { didSet { if codes != oldValue { LearnedCodes.save(codes) } } }
    @Published var learning: LearnSession?
    @Published var token: TuyaToken? = TokenStore.load()
    @Published var devices: [DeviceInfo] = []
    @Published var loadingDevices = false
    @Published var setupError: String?

    // Phone audio route (Bluetooth to the bar)
    @Published var phoneRoute: String?
    @Published var phoneOnBar = false

    @Published var toast: String?

    @Published var phoneVolumeButtons = (UserDefaults.standard.object(forKey: "phoneVolumeButtons") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(phoneVolumeButtons, forKey: "phoneVolumeButtons")
            updateVolumeButtons(active: phoneVolumeButtons)
        }
    }

    /// Side buttons drive the bar while Subwave is in front. Not when the bar is known to be off, and not when
    /// this phone is playing through the bar over Bluetooth (the buttons already set the bar's volume then).
    func updateVolumeButtons(active: Bool) {
        let vb = VolumeButtons.shared
        guard active, phoneVolumeButtons, isSetUp else { vb.stop(); return }
        vb.shouldIntercept = { [weak self] in
            guard let self else { return false }
            return self.state.power != false && !self.phoneOnBar
        }
        vb.onStep = { [weak self] n in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await Bar.perform(n > 0 ? .volumeUp(n) : .volumeDown(-n), cfg: self.bar)
                    self.state = BarState.stored
                } catch {
                    self.show(error.localizedDescription)
                }
            }
        }
        vb.start()
    }

    let cast = CastClient()
    private var poller: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var learnTimeout: Task<Void, Never>?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Store.shared.readRoute() }
        }
        readRoute()
    }

    var isSetUp: Bool { bar.hasWiFi || blaster.isReady }

    // MARK: - Polling

    func startPolling() {
        poller?.cancel()
        if bar.hasWiFi { cast.connect(host: bar.host) }
        poller = Task {
            var tick = 0
            while !Task.isCancelled {
                await refresh(full: tick % 5 == 0)
                tick += 1
                try? await Task.sleep(nanoseconds: (state.power == true ? 3 : 8) * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
        cast.disconnect()
    }

    func refresh(full: Bool = false) async {
        guard bar.hasWiFi else {
            state = BarState.stored
            return
        }
        let before = state
        let s = await Bar.refresh(cfg: bar)
        if volumeDraft == nil { state = s } else { var t = s; t.volume = state.volume; state = t }
        wifiReachable = s.updated > Date().addingTimeInterval(-10) && s.via == BarPath.wifi.rawValue
        if before.power != s.power || before.volume != s.volume || before.muted != s.muted { WidgetCenter.shared.reloadAllTimelines() }
        if full || inputs.isEmpty, s.power == true, let sc = SmartCast(bar) {
            if let list = try? await sc.inputs(), !list.isEmpty {
                inputs = list
                InputCache.save(list.map { CachedInput(name: $0.name, label: Self.inputLabel($0)) })
            }
            if let items = try? await SoundMenu.audioItems(sc), !items.isEmpty { soundItems = items }
        }
        if full, tv.isSet { tvOn = await TV.isOn(tv) }
    }

    /// SmartCast input names are things like "HDMI-ARC" or "BT"; make them readable.
    static func inputLabel(_ i: SCItem) -> String {
        let n = i.name
        switch n.uppercased() {
        case "BT", "BLUETOOTH": return "Bluetooth"
        case "HDMI-ARC", "ARC", "HDMI ARC": return "TV (ARC)"
        case "EARC", "HDMI-EARC": return "TV (eARC)"
        case "OPTICAL": return "Optical"
        case "AUX": return "AUX"
        case "USB": return "USB"
        case "COAX", "COAXIAL": return "Coaxial"
        case "CAST", "SMARTCAST": return "Cast"
        default: return n
        }
    }

    // MARK: - Commands

    func perform(_ a: BarAction) {
        haptic.impactOccurred()
        Task {
            do {
                let path = try await Bar.perform(a, cfg: bar)
                lastPath = path
                state = BarState.stored
                if case .power(let on) = a, on == false { Donate.off() }
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func setSound(_ it: SCItem, _ value: String) {
        guard let sc = SmartCast(bar) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let i = soundItems.firstIndex(where: { $0.id == it.id }) { soundItems[i].value = .string(value) }
        Task {
            do {
                try await sc.set(it.path, value)
                lastPath = .wifi
            } catch {
                show(error.localizedDescription)
                if let items = try? await SoundMenu.audioItems(sc) { soundItems = items }
            }
        }
    }

    func setVolumeLive(_ v: Double) {
        volumeDraft = v
        state.volume = Int(v.rounded())
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await Bar.perform(.setVolume(Int(v.rounded())), cfg: bar)
            } catch {
                show(error.localizedDescription)
            }
            if volumeDraft == v { volumeDraft = nil }
        }
    }

    func run(_ p: BarPreset) {
        haptic.impactOccurred()
        show("\(p.name)…")
        Task {
            do {
                try await Presets.run(p)
                Donate.preset(p)
                show(p.name)
                await refresh()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    // MARK: - Sound bar setup

    /// Checks an address, finds the SmartCast port and reads the bar's name.
    func connectBar(host: String, name: String? = nil, model: String? = nil) async -> String? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return "Type the sound bar's IP address." }
        guard let port = await SmartCast.findPort(host: h, auth: bar.auth, preferred: bar.port) else {
            return "Nothing answered SmartCast at \(h). Check the IP, that the bar is on the same Wi-Fi, and that Subwave has Local Network access (iOS Settings › Subwave)."
        }
        var b = bar
        b.host = h
        b.port = port
        if let name { b.name = name }
        if let model { b.model = model }
        if let info = try? await SmartCast(host: h, port: port, auth: b.auth).deviceInfo() {
            if let n = info.name, !n.isEmpty { b.name = n }
            if let m = info.model, !m.isEmpty { b.model = m }
        }
        bar = b
        cast.disconnect()
        cast.connect(host: h)
        inputs = []
        await refresh(full: true)
        Task { await BridgeSync.pushIfChanged() }
        return nil
    }

    func forgetBar() {
        cast.disconnect()
        var b = BarConfig()
        b.route = blaster.isReady ? .ir : .auto
        bar = b
        inputs = []
        state = BarState()
        BarState.stored = state
    }

    func startPair() async {
        guard let sc = SmartCast(bar) else { return }
        do { pairing = try await sc.beginPair(deviceID: bar.deviceID) } catch { show(error.localizedDescription) }
    }

    func finishPair(pin: String) async {
        guard let sc = SmartCast(bar), let p = pairing else { return }
        do {
            let t = try await sc.finishPair(deviceID: bar.deviceID, challenge: p.challenge, token: p.token, pin: pin)
            bar.auth = t
            pairing = nil
            show("Paired")
            await refresh(full: true)
        } catch {
            show(error.localizedDescription)
        }
    }

    // MARK: - Phone audio route

    func readRoute() {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        let bt = outs.first { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }
        phoneRoute = bt?.portName ?? outs.first?.portName
        if let n = bt?.portName.lowercased() {
            let barName = bar.name.lowercased()
            phoneOnBar = n.contains("vizio") || (!barName.isEmpty && n.contains(barName))
        } else {
            phoneOnBar = false
        }
    }

    // MARK: - Smart Life (once, for the blaster's local key)

    func signedIn(_ t: TuyaToken) {
        TokenStore.save(t)
        token = t
        Task { await loadDevices() }
    }

    func signOutCloud() {
        TokenStore.clear()
        token = nil
        devices = []
    }

    func loadDevices() async {
        guard let token else { return }
        loadingDevices = true
        setupError = nil
        defer { loadingDevices = false }
        do {
            let list = try await TuyaClient(token: token).allDevices()
            devices = list.sorted { a, b in
                if a.isBlaster != b.isBlaster { return a.isBlaster }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            if devices.isEmpty { setupError = "No devices came back from Smart Life." }
        } catch {
            if let te = error as? TuyaError, te.isAuth { signOutCloud() }
            setupError = error.localizedDescription
        }
    }

    func choose(_ d: DeviceInfo) {
        guard let key = d.localKey, !key.isEmpty else {
            setupError = "Smart Life didn't hand over a local key for \(d.name)."
            return
        }
        if d.isSub {
            setupError = "\(d.name) is paired through a hub, not on Wi-Fi by itself, so it can't be reached directly. Pick the Wi-Fi blaster, or re-pair it straight to Wi-Fi in Smart Life."
        }
        setBlaster(devId: d.id, key: key, name: d.name)
    }

    func setBlaster(devId: String, key: String, name: String?, host: String? = nil) {
        let same = blaster.devId == devId
        Task { await IRSender.shared.drop() }
        var b = blaster
        b.devId = devId
        b.localKey = key
        b.name = name ?? b.name ?? "IR blaster"
        if !same { b.host = nil; b.version = nil; b.detected = nil }
        if let host, !host.isEmpty { b.host = host; b.version = nil }
        blaster = b
        if b.host == nil { findBlaster() } else { connectBlaster() }
    }

    func forgetBlaster() {
        Task { await IRSender.shared.drop() }
        blaster = BlasterConfig()
        blasterState = .off
        if bar.route == .ir { bar.route = .auto }
    }

    func setBlasterHost(_ host: String) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        Task { await IRSender.shared.drop() }
        blaster.host = h
        blaster.version = nil
        connectBlaster()
    }

    func refreshKey() async {
        guard let devId = blaster.devId else { return }
        await loadDevices()
        if let d = devices.first(where: { $0.id == devId }), let key = d.localKey, !key.isEmpty {
            if key != blaster.localKey {
                blaster.localKey = key
                await IRSender.shared.drop()
                connectBlaster()
                show("Got a new local key")
            } else {
                show("Key is already current")
            }
        }
    }

    func connectBlaster() {
        guard blaster.isReady else { return }
        blasterState = .connecting
        Task {
            await IRSender.shared.listen { dps in Task { @MainActor in Store.shared.receiveIR(dps) } }
            do {
                let v = try await IRSender.shared.connect()
                var b = BlasterConfig.stored
                if b.detected == nil {
                    var f: IRFormat?
                    if let dps = try? await IRSender.shared.query() { f = IRCommand.hint(dps) }
                    if f == nil { f = await probeFormat() }
                    b.detected = f
                }
                blaster = b
                blasterState = .connected(v)
                if !bar.hasWiFi && bar.route == .auto { bar.route = .ir }
                Task { await BridgeSync.pushIfChanged() }
            } catch {
                blaster = BlasterConfig.stored
                blasterState = .failed("Couldn't reach the blaster: \(error.localizedDescription)")
            }
        }
    }

    /// Same trick as tinytuya: poke both formats with a harmless "exit learning" and see which data point answers.
    private var seenDPs: Set<String> = []
    private func probeFormat() async -> IRFormat? {
        seenDPs = []
        try? await IRSender.shared.raw(IRCommand.studyExit(.classic))
        try? await IRSender.shared.raw(IRCommand.studyExit(.modern))
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let dps = try? await IRSender.shared.query(), let h = IRCommand.hint(dps) { return h }
        if seenDPs.contains("201") || seenDPs.contains("202") { return .classic }
        if seenDPs.contains("1") || seenDPs.contains("2") { return .modern }
        return nil
    }

    /// Listens for the blaster's own broadcast while scanning the Wi-Fi for Tuya's port, then checks the key on
    /// every candidate at once. Prefers a device that answered with something encrypted with our key.
    func findBlaster() {
        guard let devId = blaster.devId, let key = blaster.localKey else { return }
        blasterState = .searching("Scanning your Wi-Fi…")
        blasterLog = []
        Task {
            await IRSender.shared.drop()
            async let heardList = LocalScan.listen(seconds: 7)
            let scanned = await LocalScan.openHosts { n in
                Task { @MainActor in
                    if case .searching = Store.shared.blasterState { Store.shared.blasterState = .searching("Scanning your Wi-Fi… \(n)/254") }
                }
            }
            let heardAll = await heardList
            let heard = heardAll.first { $0.devId == devId }
            var log: [String] = []
            if let heard {
                log.append("Blaster announced itself at \(heard.ip), protocol \(heard.version).")
            } else if !heardAll.isEmpty {
                log.append("Heard \(heardAll.count) Tuya broadcast\(heardAll.count == 1 ? "" : "s"), none from this blaster.")
            }
            var hosts = scanned
            if let heard { hosts.removeAll { $0 == heard.ip }; hosts.insert(heard.ip, at: 0) }
            if hosts.isEmpty {
                blasterLog = log
                blasterState = .failed("Nothing on your Wi-Fi answered on Tuya's port. Allow Local Network for Subwave in iOS Settings, or type the blaster's IP.")
                return
            }
            blasterState = .searching("Checking the key on \(hosts.count) Tuya device\(hosts.count == 1 ? "" : "s")…")

            // The blaster's own broadcast is definitive: try it first, with the version it gave.
            if let heard, let r = try? await LocalLink.detectFull(devId: devId, host: heard.ip, localKey: key, knownDPs: [], timeout: 3,
                                                                    versions: [heard.version] + [3.3, 3.4, 3.5].filter { $0 != heard.version },
                                                                    probe: IRCommand.probes, onDPS: { _ in }, onClose: { _ in }) {
                await r.link.close()
                blasterLog = log
                useBlaster(host: heard.ip, version: r.link.version)
                return
            }

            var strong: (String, Double)?
            var weak: [(String, Double)] = []
            await withTaskGroup(of: (String, Double?, KeyProof?, String?).self) { group in
                for host in hosts {
                    group.addTask {
                        do {
                            let r = try await LocalLink.detectFull(devId: devId, host: host, localKey: key, knownDPs: [], timeout: 3,
                                                                   probe: IRCommand.probes, onDPS: { _ in }, onClose: { _ in })
                            await r.link.close()
                            return (host, r.link.version, r.proof, nil)
                        } catch {
                            return (host, nil, nil, LocalLink.short(error))
                        }
                    }
                }
                for await (host, version, proof, err) in group {
                    if let version, let proof {
                        log.append("\(host): took the key (protocol \(version)\(proof == .weak ? ", acknowledged only" : "")).")
                        if proof == .strong, strong == nil { strong = (host, version) } else if proof == .weak { weak.append((host, version)) }
                    } else {
                        log.append("\(host): \(err ?? "no answer")")
                    }
                }
            }
            blasterLog = log
            if let strong {
                useBlaster(host: strong.0, version: strong.1)
            } else if weak.count == 1 {
                useBlaster(host: weak[0].0, version: weak[0].1)
            } else if weak.count > 1 {
                blasterState = .failed("\(weak.count) devices acknowledged but none proved the key (\(weak.map { $0.0 }.joined(separator: ", "))). Type the blaster's IP from your router.")
            } else {
                var why = "Found \(hosts.count) Tuya device\(hosts.count == 1 ? "" : "s") but none took the blaster's key."
                if let d = devices.first(where: { $0.id == devId }) {
                    if d.isSub { why += " Smart Life says this blaster is paired through a hub, so it has no Wi-Fi connection of its own." }
                    else if !d.online { why += " Smart Life says the blaster is offline." }
                }
                why += " Close Smart Life and the other blaster apps (it may only take one connection at a time), then try again. If you re-paired it, refresh the key."
                blasterState = .failed(why)
            }
        }
    }

    private func useBlaster(host: String, version: Double) {
        blaster.host = host
        blaster.version = version
        connectBlaster()
    }

    // MARK: - IR learning

    func receiveIR(_ dps: [String: JSONValue]) {
        guard !dps.isEmpty else { return }
        seenDPs.formUnion(dps.keys)
        guard var s = learning, s.phase == .waiting || s.phase == .starting, let got = IRCommand.learned(in: dps) else { return }
        if blaster.forced == nil, blaster.detected != got.format { blaster.detected = got.format }
        codes[s.keyID] = got.code
        s.phase = .captured(IRPulses.pulses(got.code)?.count ?? 0)
        learning = s
        learnTimeout?.cancel()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await IRSender.shared.raw(IRCommand.studyExit(blaster.format))
            await IRSender.shared.setHold(false)
            if s.keyID == "power" { await BridgeSync.pushIfChanged() }
        }
    }

    func startLearn(_ keyID: String) {
        guard blaster.isReady else { show("Set up the IR blaster first."); return }
        learnTimeout?.cancel()
        var s = learning ?? LearnSession(keyID: keyID, label: IRKeys.def(keyID)?.label ?? keyID)
        s.keyID = keyID
        s.label = IRKeys.def(keyID)?.label ?? keyID
        s.phase = .starting
        learning = s
        Task {
            await IRSender.shared.listen { dps in Task { @MainActor in Store.shared.receiveIR(dps) } }
            await IRSender.shared.setHold(true)
            do {
                let f = blaster.format
                try await IRSender.shared.raw(IRCommand.studyExit(f))
                try await Task.sleep(nanoseconds: 150_000_000)
                try await IRSender.shared.raw(IRCommand.study(f))
                if learning?.phase == .starting { learning?.phase = .waiting }
                learnTimeout = Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, learning?.phase == .waiting else { return }
                    learning?.phase = .failed("Nothing came in. Hold the Vizio remote 5 to 10 cm from the blaster, aim at it, and press once firmly.")
                    try? await IRSender.shared.raw(IRCommand.studyExit(blaster.format))
                    await IRSender.shared.setHold(false)
                }
            } catch {
                learning?.phase = .failed(error.localizedDescription)
                await IRSender.shared.setHold(false)
            }
        }
    }

    func endLearn() {
        learnTimeout?.cancel()
        if let s = learning, s.phase == .waiting || s.phase == .starting {
            Task { try? await IRSender.shared.raw(IRCommand.studyExit(blaster.format)) }
        }
        Task { await IRSender.shared.setHold(false) }
        learning = nil
    }

    func testIR(_ keyID: String) {
        guard let code = IRKeys.code(keyID, learned: codes) else { show("No code for that button yet."); return }
        haptic.impactOccurred()
        Task {
            do { try await IRSender.shared.send(code) } catch { show(error.localizedDescription) }
        }
    }

    func importRedshift(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url), let got = LearnedCodes.fromRedshift(d) else {
            show("No sound bar remote in that file. In Redshift: Settings › Export remotes.")
            return
        }
        if got.isEmpty { show("Redshift's sound bar remote has no learned buttons yet."); return }
        codes.merge(got) { _, new in new }
        show("Imported \(got.count) button\(got.count == 1 ? "" : "s") from Redshift")
        Task { await BridgeSync.pushIfChanged() }
    }

    // MARK: - Bridge

    func pairBridge(host: String, port: Int) async -> String? {
        var cfg = BridgeConfig(host: host, port: port)
        do {
            let info = try await BridgeAPI.info(cfg)
            bridgeInfo = info
            cfg.token = try await BridgeAPI.claim(cfg)
            bridge = cfg
            return await BridgeSync.pushIfChanged(force: true)
        } catch {
            return error.localizedDescription
        }
    }

    func refreshBridge() async {
        guard bridge.isSet else { return }
        bridgeInfo = try? await BridgeAPI.info(bridge)
    }

    func forgetBridge() {
        bridge = BridgeConfig()
        bridgeInfo = nil
    }

    // MARK: - Presets

    func savePreset(_ p: BarPreset) {
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
    }

    func deletePreset(_ id: String) { presets.removeAll { $0.id == id } }

    // MARK: - Messages

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }
}
