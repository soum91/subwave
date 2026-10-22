import SwiftUI
import AVKit

/// Two pages: the bar, and the remote with every button.
struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Sound bar", systemImage: "hifispeaker.fill") }
                .tag(0)
            NavigationStack { IRRemoteView() }
                .tabItem { Label("Remote", systemImage: "av.remote.fill") }
                .tag(1)
        }
        .sheet(item: Binding(get: { store.learning }, set: { if $0 == nil { store.endLearn() } })) { _ in
            LearnSheet().environmentObject(store).presentationDetents([.medium])
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var cast = Store.shared.cast
    @State private var showSetup = false
    @State private var showSettings = false
    @State private var editing: BarPreset?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background(store.state.power == true ? Theme.accent : Theme.off, strength: store.state.power == true ? 0.24 : 0.12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if !store.isSetUp {
                            setupCard
                        } else {
                            powerAndVolume
                            inputsRow
                            presetsRow
                            if cast.status.app != nil && !cast.status.isIdleScreen { NowPlayingCard() }
                            soundCard
                            BluetoothCard()
                            moreCard
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
                .refreshable { await store.refresh(full: true) }

                if let t = store.toast { Toast(text: t).padding(.bottom, 24) }
            }
            .animation(.easeInOut(duration: 0.2), value: store.toast)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSetup) { SetupView().environmentObject(store) }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
            .sheet(item: $editing) { p in PresetEditor(preset: p).environmentObject(store) }
        }
    }

    // MARK: Header

    private var statusText: String {
        let s = store.state
        var parts: [String] = []
        switch s.power {
        case true?: parts.append("On")
        case false?: parts.append("Standby")
        default: parts.append(store.bar.hasWiFi ? "Not answering" : "IR only")
        }
        if s.power == true, let i = s.input { parts.append(i) }
        if let v = store.lastPath?.rawValue ?? s.via { parts.append("via \(v)") }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.bar.name.isEmpty ? "Subwave" : store.bar.name)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if store.isSetUp {
                    HStack(spacing: 6) {
                        Circle().fill(store.state.power == true ? Theme.accent : Theme.off).frame(width: 8, height: 8)
                        Text(statusText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let m = store.bar.model { Text(m).font(.caption).foregroundStyle(.white.opacity(0.35)) }
                }
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(Theme.card, in: Circle())
                    .foregroundStyle(.white)
            }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "hifispeaker.2.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Let's find your sound bar").font(.title2.bold())
            Text("Subwave talks to the Vizio straight over your Wi-Fi (SmartCast, what Vizio's app uses underneath) and through your Tuya IR blaster when the bar is asleep or the Wi-Fi side flakes out. No Vizio account.")
                .foregroundStyle(.secondary)
            Button { showSetup = true } label: {
                Text("Set up").fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black)
            }
        }
        .card()
    }

    // MARK: Power and volume

    private var volumeValue: Double { Double(store.state.volume ?? 0) }

    private var powerAndVolume: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                Button { store.perform(.power(store.state.power == true ? false : (store.state.power == false ? true : nil))) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 84, height: 84)
                        .background(store.state.power == true ? Theme.accent : Color.white.opacity(0.08), in: Circle())
                        .foregroundStyle(store.state.power == true ? .black : .white)
                        .overlay(Circle().stroke(Theme.stroke))
                        .shadow(color: store.state.power == true ? Theme.accent.opacity(0.5) : .clear, radius: 18)
                }
                .buttonStyle(PressStyle())
                .contextMenu {
                    Button { store.perform(.power(true)) } label: { Label("Power on", systemImage: "power.circle.fill") }
                    Button { store.perform(.power(false)) } label: { Label("Power off", systemImage: "power.circle") }
                    Button { store.perform(.irKey("power")) } label: { Label("Send power toggle (IR)", systemImage: "dot.radiowaves.right") }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.state.volume.map { "\($0)" } ?? "–")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(store.state.muted == true ? Theme.off : .white)
                    Text(store.state.muted == true ? "Muted" : "Volume").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.perform(.mute(nil)) } label: {
                    Image(systemName: store.state.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 54, height: 54)
                        .background(store.state.muted == true ? Theme.danger : Color.white.opacity(0.08), in: Circle())
                        .foregroundStyle(store.state.muted == true ? .black : .white)
                }
                .buttonStyle(PressStyle())
            }

            HStack(spacing: 12) {
                stepButton("minus") { store.perform(.volumeDown(1)) }
                if store.bar.hasWiFi && store.bar.route != .ir {
                    Slider(value: Binding(get: { store.volumeDraft ?? volumeValue }, set: { store.setVolumeLive($0) }), in: 0...100, step: 1)
                        .tint(Theme.accent)
                } else {
                    Text("IR: hold to repeat").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                stepButton("plus") { store.perform(.volumeUp(1)) }
            }
        }
        .card()
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        RepeatButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.08), in: Circle())
                .foregroundStyle(.white)
        }
    }

    // MARK: Inputs

    private struct InputChoice: Identifiable {
        let id: String
        let label: String
        let symbol: String
    }

    private var inputChoices: [InputChoice] {
        if !store.inputs.isEmpty {
            return store.inputs.map { i in
                let key = Bar.inputKey(i.name)
                return InputChoice(id: i.name, label: Store.inputLabel(i),
                                   symbol: key.flatMap { IRKeys.def($0)?.symbol } ?? "rectangle.portrait.and.arrow.forward")
            }
        }
        return IRKeys.all.filter { $0.group == .inputs && ["hdmiArc", "bluetooth", "optical", "aux", "hdmiIn"].contains($0.id) }
            .map { InputChoice(id: $0.id, label: $0.label, symbol: $0.symbol ?? "rectangle.portrait.and.arrow.forward") }
    }

    private func isCurrent(_ id: String, _ label: String) -> Bool {
        guard let cur = store.state.input?.lowercased() else { return false }
        return cur == id.lowercased() || cur == label.lowercased()
    }

    private var inputsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Input")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(inputChoices) { c in
                        Button { store.perform(.input(c.id)) } label: {
                            Chip(title: c.label, symbol: c.symbol, selected: isCurrent(c.id, c.label))
                        }
                    }
                }
            }
        }
    }

    // MARK: Presets

    private var presetsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Presets")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.presets) { p in
                        Button { store.run(p) } label: { Chip(title: p.name, symbol: p.icon) }
                            .contextMenu {
                                Button { editing = p } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { store.deletePreset(p.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    Button { editing = BarPreset(name: "New preset", icon: "sparkles") } label: { Chip(title: "", symbol: "plus") }
                }
            }
            Text("Tap to run, long-press to edit.").font(.caption2).foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: Sound

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(text: "Sound")
                Spacer()
                NavigationLink { SoundSettingsView() } label: {
                    Label("All sound settings", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold))
                }
            }
            HStack(spacing: 0) {
                ForEach(["eqMovie", "eqMusic", "eqGame", "eqDirect"], id: \.self) { k in
                    if let d = IRKeys.def(k) {
                        KeyButton(symbol: d.symbol, label: d.label, size: 52) { store.perform(.irKey(k)) }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                pairToggle("Night", on: "nightOn", off: "nightOff", symbol: "moon.fill")
                pairToggle("TruVolume", on: "truVolOn", off: "truVolOff", symbol: "speaker.wave.2.fill")
                pairToggle("Virtual:X", on: "vxOn", off: "vxOff", symbol: "cube.fill")
                pairToggle("Surround", on: "surroundOn", off: "surroundOff", symbol: "hifispeaker.2.fill")
            }
            Divider().overlay(Theme.stroke)
            VStack(spacing: 10) {
                levelRow("Bass", "bassDown", "bassUp")
                levelRow("Treble", "trebleDown", "trebleUp")
                levelRow("Dialogue", "dialogDown", "dialogUp")
                levelRow("Subwoofer", "subDown", "subUp")
            }
        }
        .card()
    }

    private func pairToggle(_ label: String, on: String, off: String, symbol: String) -> some View {
        let item = store.bar.route == .ir ? nil : SoundMenu.listItem(for: on, in: store.soundItems)
        let current = item?.stringValue
        let active = current.map { $0.lowercased() != "off" } ?? false
        return Menu {
            if let item {
                // The bar's real choices, so nothing gets flattened to plain on/off.
                ForEach(item.choices, id: \.self) { c in
                    Button { store.setSound(item, c) } label: {
                        if c == current { Label(c, systemImage: "checkmark") } else { Text(c) }
                    }
                }
            } else {
                Button { store.perform(.irKey(on)) } label: { Label("\(label) on", systemImage: symbol) }
                Button { store.perform(.irKey(off)) } label: { Label("\(label) off", systemImage: "xmark") }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(active ? Theme.accent : Color.white.opacity(0.08), in: Circle())
                    .foregroundStyle(active ? .black : .white)
                    .overlay(Circle().stroke(Theme.stroke))
                Text(current.map { "\(label): \($0)" } ?? label)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private func levelRow(_ label: String, _ down: String, _ up: String) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.medium))
            Spacer()
            RepeatButton(action: { store.perform(.irKey(down)) }) {
                Image(systemName: "minus").frame(width: 40, height: 34).background(Color.white.opacity(0.08), in: Capsule())
            }
            RepeatButton(action: { store.perform(.irKey(up)) }) {
                Image(systemName: "plus").frame(width: 40, height: 34).background(Color.white.opacity(0.08), in: Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    private var moreCard: some View {
        VStack(spacing: 0) {
            NavigationLink { MenuBrowserView(path: SmartCast.settingsRoot, title: "Bar settings") } label: {
                row("Bar settings", "list.bullet.indent", "Everything the bar exposes over Wi-Fi")
            }
            .disabled(!store.bar.hasWiFi)
            Divider().overlay(Theme.stroke)
            NavigationLink { BridgeView() } label: {
                row("Follow the TV", "tv.and.hifispeaker.fill", store.bridge.isPaired ? "Runs on your Afterglow bridge" : "Bar off when the TV goes off")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }

    private func row(_ title: String, _ symbol: String, _ sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.3))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Fires once on tap and keeps firing while held, like a real remote.
struct RepeatButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var timer: Timer?
    @State private var pressed = false

    var body: some View {
        label()
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.spring(response: 0.2), value: pressed)
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 30, perform: {}, onPressingChanged: { down in
                pressed = down
                if down {
                    action()
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                        Task { @MainActor in
                            timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { _ in
                                Task { @MainActor in action() }
                            }
                        }
                    }
                } else {
                    timer?.invalidate()
                    timer = nil
                }
            })
    }
}

// MARK: - Now playing (Google Cast)

struct NowPlayingCard: View {
    @ObservedObject private var cast = Store.shared.cast
    @State private var scrub: Double?

    var body: some View {
        let s = cast.status
        let m = s.media
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Casting · \(s.app ?? "")")
                Spacer()
                Button { cast.stopApp() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
            }
            HStack(spacing: 14) {
                AsyncImage(url: m?.artURL) { img in img.resizable().scaledToFill() } placeholder: {
                    ZStack { Theme.card; Image(systemName: "music.note").foregroundStyle(.white.opacity(0.4)) }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(m?.title ?? s.app ?? "Casting").font(.headline).lineLimit(1)
                    if let sub = m?.subtitle { Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            if let m, let d = m.duration, d > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { scrub ?? m.livePosition }, set: { scrub = $0 }), in: 0...d, onEditingChanged: { editing in
                            if !editing, let v = scrub { cast.seek(v); scrub = nil }
                        })
                        .tint(.white)
                        .disabled(!m.canSeek)
                        HStack {
                            Text(Self.time(scrub ?? m.livePosition))
                            Spacer()
                            Text(Self.time(d))
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button { cast.previous() } label: { Image(systemName: "backward.fill").font(.title2) }.disabled(m == nil)
                Spacer()
                Button { cast.playPause() } label: {
                    Image(systemName: m?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 60, height: 60)
                        .background(Color.white, in: Circle())
                        .foregroundStyle(.black)
                }
                .disabled(m == nil)
                Spacer()
                Button { cast.next() } label: { Image(systemName: "forward.fill").font(.title2) }.disabled(m == nil)
                Spacer()
            }
            .foregroundStyle(.white)
        }
        .card()
    }

    static func time(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Bluetooth

struct BluetoothCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Bluetooth")
                Spacer()
                if store.phoneOnBar {
                    Label("This phone is connected", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 10) {
                Button { store.perform(.input("bluetooth")) } label: {
                    Label("Switch to BT", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { store.perform(.irKey("btPair")); store.show("Bar is in pairing mode. Pick it in the list.") } label: {
                    Label("Pair mode", systemImage: "personalhotspot").frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            HStack(spacing: 12) {
                RoutePicker().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play this phone through the bar").font(.subheadline.weight(.semibold))
                    Text(store.phoneRoute.map { "Now: \($0)" } ?? "Tap the icon and pick the bar.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = URL(string: "App-prefs:Bluetooth") {
                    Link(destination: url) { Image(systemName: "gear").foregroundStyle(.white.opacity(0.6)) }
                }
            }
        }
        .card()
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
