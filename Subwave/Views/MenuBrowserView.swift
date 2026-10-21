import SwiftUI

/// Opens the bar's audio menu if it has one, otherwise the settings root.
struct SoundSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var path: String?
    @State private var failed: String?

    var body: some View {
        Group {
            if let path {
                MenuBrowserView(path: path, title: "Sound")
            } else if !store.bar.hasWiFi {
                ZStack {
                    Theme.background()
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Sound settings need the bar on Wi-Fi. The buttons on the home screen and the full remote work over IR.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding(30)
                }
            } else {
                ZStack {
                    Theme.background()
                    if let failed {
                        Text(failed).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                    } else {
                        ProgressView()
                    }
                }
                .task { await locate() }
            }
        }
    }

    private func locate() async {
        guard let sc = SmartCast(store.bar) else { return }
        do {
            let root = try await sc.menu()
            let audio = root.first { $0.kind == .menu && $0.cname.lowercased() == "audio" }
                ?? root.first { $0.kind == .menu && ($0.cname + $0.name).lowercased().contains("audio") }
            path = audio?.path ?? SmartCast.settingsRoot
        } catch {
            failed = error.localizedDescription
        }
    }
}

/// Every setting in one SmartCast menu: sliders, switches, pickers, submenus and actions.
struct MenuBrowserView: View {
    @EnvironmentObject var store: Store
    let path: String
    let title: String

    @State private var items: [SCItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var drafts: [String: Double] = [:]
    @State private var confirm: SCItem?
    @State private var setTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.background()
            List {
                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
                Section {
                    ForEach(items.filter { !$0.hidden }) { it in row(it) }
                } footer: {
                    if !loading && items.isEmpty && error == nil { Text("Nothing in this menu.") }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay { if loading && items.isEmpty { ProgressView() } }
            .refreshable { await load() }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(confirm?.name ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let it = confirm {
                Button(it.name, role: isDangerous(it) ? .destructive : nil) { act(it) }
            }
        } message: {
            if let it = confirm, isDangerous(it) { Text("This can't be undone.") }
        }
    }

    private func isDangerous(_ it: SCItem) -> Bool {
        let n = (it.name + it.cname).lowercased()
        return n.contains("reset") || n.contains("factory") || n.contains("restore")
    }

    @ViewBuilder
    private func row(_ it: SCItem) -> some View {
        switch it.kind {
        case .menu:
            NavigationLink { MenuBrowserView(path: it.path, title: it.name) } label: {
                Label(it.name, systemImage: Self.symbol(for: it))
            }
        case .slider:
            sliderRow(it)
        case .list, .xlist:
            if it.isToggle {
                Toggle(isOn: Binding(get: { it.stringValue?.lowercased() == "on" }, set: { on in
                    set(it, it.choices.first { $0.lowercased() == (on ? "on" : "off") } ?? (on ? "On" : "Off"))
                })) {
                    Label(it.name, systemImage: Self.symbol(for: it))
                }
                .disabled(it.readOnly)
                .tint(Theme.accent)
            } else if it.choices.isEmpty {
                valueRow(it)
            } else {
                Picker(selection: Binding(get: { it.stringValue ?? "" }, set: { set(it, $0) })) {
                    ForEach(it.choices, id: \.self) { Text($0).tag($0) }
                } label: {
                    Label(it.name, systemImage: Self.symbol(for: it))
                }
                .disabled(it.readOnly)
            }
        case .action:
            Button { confirm = it } label: {
                Label(it.name, systemImage: isDangerous(it) ? "exclamationmark.triangle" : "play.circle")
                    .foregroundStyle(isDangerous(it) ? Theme.danger : .white)
            }
        case .value, .other:
            if it.min != nil && it.max != nil && !it.readOnly { sliderRow(it) } else { valueRow(it) }
        }
    }

    private func valueRow(_ it: SCItem) -> some View {
        HStack {
            Label(it.name, systemImage: Self.symbol(for: it))
            Spacer()
            Text(it.stringValue ?? "–").foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func sliderRow(_ it: SCItem) -> some View {
        let lo = Double(it.min ?? 0), hi = Double(max((it.max ?? 100), (it.min ?? 0) + 1))
        let v = drafts[it.id] ?? Double(it.intValue ?? it.center ?? 0)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(it.name, systemImage: Self.symbol(for: it))
                Spacer()
                Text("\(Int(v))").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { nudge(it, -1, lo, hi) } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                Slider(value: Binding(get: { v }, set: { new in
                    drafts[it.id] = new.rounded()
                    setTask?.cancel()
                    setTask = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        set(it, Int(new.rounded()))
                    }
                }), in: lo...hi, step: 1)
                .tint(Theme.accent)
                Button { nudge(it, 1, lo, hi) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            .disabled(it.readOnly)
        }
        .padding(.vertical, 4)
    }

    private func nudge(_ it: SCItem, _ d: Int, _ lo: Double, _ hi: Double) {
        let now = drafts[it.id] ?? Double(it.intValue ?? 0)
        let v = min(hi, max(lo, now + Double(d)))
        drafts[it.id] = v
        set(it, Int(v))
    }

    private func load() async {
        guard let sc = SmartCast(store.bar) else { error = "The bar isn't set up on Wi-Fi."; loading = false; return }
        loading = true
        defer { loading = false }
        do {
            items = try await sc.fullMenu(path)
            drafts = [:]
            error = nil
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func set(_ it: SCItem, _ value: Any) {
        guard let sc = SmartCast(store.bar) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await sc.set(it.path, value)
                if let i = items.firstIndex(where: { $0.id == it.id }) {
                    items[i].value = JSONValue.from(value)
                }
            } catch let e {
                store.show(e.localizedDescription)
                await load()
            }
        }
    }

    private func act(_ it: SCItem) {
        guard let sc = SmartCast(store.bar) else { return }
        Task {
            do {
                try await sc.action(it.path)
                store.show("\(it.name) done")
            } catch let e {
                store.show(e.localizedDescription)
            }
        }
    }

    static func symbol(for it: SCItem) -> String {
        let n = (it.name + " " + it.cname).lowercased()
        let map: [(String, String)] = [
            ("bass", "speaker.wave.1.fill"), ("treble", "waveform"), ("sub", "hifispeaker.fill"),
            ("center", "dot.circle.and.hand.point.up.left.fill"), ("surround", "hifispeaker.2.fill"),
            ("height", "arrow.up.to.line"), ("dialog", "text.bubble.fill"), ("speech", "text.bubble.fill"),
            ("night", "moon.fill"), ("volume", "speaker.wave.2.fill"), ("mute", "speaker.slash.fill"),
            ("eq", "slider.vertical.3"), ("mode", "slider.horizontal.3"), ("virtual", "cube.fill"),
            ("dts", "cube.transparent"), ("dolby", "cube.transparent"), ("delay", "timer"), ("lip", "timer"),
            ("bluetooth", "dot.radiowaves.left.and.right"), ("input", "rectangle.portrait.and.arrow.forward"),
            ("network", "wifi"), ("wifi", "wifi"), ("led", "light.max"), ("light", "light.max"), ("display", "display"),
            ("name", "character.cursor.ibeam"), ("reset", "arrow.counterclockwise"), ("power", "power"),
            ("cec", "tv"), ("hdmi", "cable.connector"), ("system", "gearshape"), ("audio", "speaker.wave.3.fill"),
            ("speaker", "hifispeaker"), ("test", "speaker.badge.exclamationmark"), ("info", "info.circle"),
            ("timer", "timer"), ("sleep", "zzz"), ("standby", "zzz"),
        ]
        return map.first { n.contains($0.0) }?.1 ?? "slider.horizontal.below.rectangle"
    }
}
