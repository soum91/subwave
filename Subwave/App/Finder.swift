import Foundation
import Network

/// A speaker seen on the network.
struct FoundBar: Identifiable, Equatable {
    var id: String { host }
    var name: String
    var host: String
    var model: String?
    /// The SmartCast port that answered, if any. Nil means it's a Cast device but not a Vizio SmartCast one.
    var port: Int?
}

/// Finds the bar by its Google Cast and Vizio SmartCast Bonjour services, then checks which ones speak SmartCast.
@MainActor
final class BarFinder: ObservableObject {
    @Published var found: [FoundBar] = []
    @Published var searching = false
    private var browsers: [NWBrowser] = []
    private var seen: Set<String> = []

    func start() {
        stop()
        searching = true
        found = []
        seen = []
        for type in ["_viziocast._tcp", "_googlecast._tcp"] {
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                for r in results {
                    guard case .service(let name, _, _, _) = r.endpoint else { continue }
                    var friendly = name, model: String?
                    if case .bonjour(let txt) = r.metadata {
                        if let fn = txt["fn"], !fn.isEmpty { friendly = fn }
                        if let md = txt["md"], !md.isEmpty { model = md }
                    }
                    let f = friendly, m = model
                    Task { @MainActor in await self?.resolve(r.endpoint, name: f, model: m) }
                }
            }
            b.start(queue: .main)
            browsers.append(b)
        }
        Task {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if searching { searching = false }
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        searching = false
    }

    private func resolve(_ endpoint: NWEndpoint, name: String, model: String?) async {
        guard let host = await Self.address(of: endpoint), !seen.contains(host) else { return }
        seen.insert(host)
        var bar = FoundBar(name: Self.clean(name), host: host, model: model)
        found.append(bar)
        bar.port = await SmartCast.findPort(host: host)
        if let i = found.firstIndex(where: { $0.host == host }) { found[i] = bar }
        // SmartCast ones first.
        found.sort { ($0.port != nil ? 0 : 1, $0.name) < ($1.port != nil ? 0 : 1, $1.name) }
    }

    /// Cast service names look like "VIZIO-SB36514-G6-1a2b3c…": keep the readable part.
    private static func clean(_ n: String) -> String {
        var s = n
        if let r = s.range(of: "-[0-9a-f]{24,}$", options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    /// Opens a throwaway connection to learn the service's IPv4 address.
    static func address(of endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        return await withCheckedContinuation { cont in
            let once = OnceFlag()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let h, _)? = c.currentPath?.remoteEndpoint, once.fire() {
                        var host = "\(h)"
                        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
                        cont.resume(returning: host)
                    } else if once.fire() { cont.resume(returning: nil) }
                    c.cancel()
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if once.fire() { cont.resume(returning: nil); c.cancel() }
            }
        }
    }
}

/// Finds the Afterglow bridge (_afterglow._tcp), which also runs the sound bar's TV rule.
@MainActor
final class BridgeFinder: ObservableObject {
    @Published var found: [(name: String, host: String, port: Int)] = []
    @Published var searching = false
    private var browser: NWBrowser?

    func start() {
        stop()
        searching = true
        found = []
        let b = NWBrowser(for: .bonjour(type: "_afterglow._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                Task { @MainActor in
                    guard let host = await BarFinder.address(of: r.endpoint) else { return }
                    guard let self, !self.found.contains(where: { $0.host == host }) else { return }
                    self.found.append((name, host, 8080))
                }
            }
        }
        b.start(queue: .main)
        browser = b
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            searching = false
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        searching = false
    }
}
