import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var tvTest: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                List {
                    Section("Sound bar") {
                        NavigationLink { FindBarView() } label: {
                            LabeledContent("Wi-Fi", value: store.bar.hasWiFi ? store.bar.host : "Not set")
                        }
                        if store.bar.hasWiFi {
                            TextField("Name", text: $store.bar.name)
                            if let m = store.bar.model { LabeledContent("Model", value: m) }
                            LabeledContent("SmartCast port", value: "\(store.bar.port ?? 7345)")
                        }
                        Picker("Send commands", selection: $store.bar.route) {
                            ForEach(BarRoute.allCases) { Text($0.title).tag($0) }
                        }
                        if store.bar.hasWiFi {
                            Button("Forget sound bar", role: .destructive) { confirmForget = true }
                        }
                    }

                    Section {
                        NavigationLink { BlasterSetupView() } label: {
                            LabeledContent("Blaster", value: store.blaster.isReady ? (store.blaster.name ?? "Set") : "Not set")
                        }
                        if store.blaster.isReady {
                            LabeledContent("Status", value: store.blasterState.text)
                            LabeledContent("Learned buttons", value: "\(store.codes.count) of \(IRKeys.all.count)")
                        }
                    } header: {
                        Text("IR blaster")
                    } footer: {
                        Text("Wi-Fi, then IR: tries SmartCast first and falls back to the blaster when the bar doesn't answer (deep standby, Vizio's Wi-Fi napping).")
                    }

                    Section {
                        TextField("TV IP address", text: $store.tv.host).keyboardType(.decimalPad)
                        SecureField("Pre-shared key (if set on the TV)", text: $store.tv.psk)
                        Button("Test") {
                            Task {
                                tvTest = "Asking…"
                                tvTest = await TV.isOn(store.tv, timeout: 3) ? "TV is on" : "Off, or not answering"
                            }
                        }
                        if let tvTest { Text(tvTest).foregroundStyle(.secondary) }
                    } header: {
                        Text("Sony TV")
                    } footer: {
                        Text("Same as Afterglow. On the TV: Network › Home network › IP control › Authentication \"Normal and Pre-Shared Key\".")
                    }

                    Section("Automation") {
                        NavigationLink { BridgeView() } label: {
                            LabeledContent("Follow the TV", value: store.bridge.isPaired ? "On the bridge" : "Not set")
                        }
                        NavigationLink { PresetListView() } label: { LabeledContent("Presets", value: "\(store.presets.count)") }
                    }

                    Section {
                        LabeledContent("Version", value: AppGroup.version + " (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        LabeledContent("Widget data", value: AppGroup.isShared ? "Shared" : "Not shared")
                        if !AppGroup.isShared {
                            Text("The sideload stripped the App Group, so the widget and Control Center can't see the bar. Reinstall with app extensions kept.")
                                .font(.caption).foregroundStyle(Theme.danger)
                        }
                        Link("Source on GitHub", destination: URL(string: "https://github.com/soum91/subwave")!)
                    } header: {
                        Text("About")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .confirmationDialog("Forget \(store.bar.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { store.forgetBar() }
            }
            .onDisappear { Task { await BridgeSync.pushIfChanged() } }
        }
    }
}

// MARK: - Presets

struct PresetListView: View {
    @EnvironmentObject var store: Store
    @State private var editing: BarPreset?

    var body: some View {
        ZStack {
            Theme.background()
            List {
                ForEach(store.presets) { p in
                    Button { editing = p } label: {
                        HStack(spacing: 12) {
                            Image(systemName: p.icon).foregroundStyle(Theme.accent).frame(width: 26)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundStyle(.white)
                                Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onDelete { idx in store.presets.remove(atOffsets: idx) }
                .onMove { from, to in store.presets.move(fromOffsets: from, toOffset: to) }
                Button { editing = BarPreset(name: "New preset", icon: "sparkles") } label: { Label("Add preset", systemImage: "plus") }
                Button("Restore default presets") { store.presets = BarPreset.defaults }.foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Presets")
        .toolbar { EditButton() }
        .sheet(item: $editing) { p in PresetEditor(preset: p).environmentObject(store) }
    }
}

struct PresetEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var preset: BarPreset
    @State private var capturing = false
    @State private var useVolume = false

    private static let icons = ["sparkles", "tv", "film", "music.note", "gamecontroller", "moon.stars.fill", "sun.max.fill",
                                "headphones", "mic.fill", "sportscourt.fill", "party.popper.fill", "bed.double.fill", "power"]
    private static let featureKeys = ["eqMovie", "eqMusic", "eqGame", "eqDirect", "nightOn", "nightOff", "truVolOn", "truVolOff",
                                      "vxOn", "vxOff", "surroundOn", "surroundOff", "surroundDual", "dialogUp", "dialogDown", "bassUp", "bassDown"]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                Form {
                    Section {
                        TextField("Name", text: $preset.name)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Self.icons, id: \.self) { i in
                                    Image(systemName: i)
                                        .frame(width: 38, height: 38)
                                        .background(preset.icon == i ? Theme.accent : Color.white.opacity(0.08), in: Circle())
                                        .foregroundStyle(preset.icon == i ? .black : .white)
                                        .onTapGesture { preset.icon = i }
                                }
                            }
                        }
                        Toggle("Turns the bar on", isOn: $preset.powerOn).tint(Theme.accent)
                    }
                    if preset.powerOn {
                        Section("Input") {
                            Picker("Input", selection: $preset.input) {
                                Text("Leave as is").tag(String?.none)
                                ForEach(InputQuery.everything()) { i in Text(i.name).tag(String?.some(i.id)) }
                                if let cur = preset.input, !InputQuery.everything().contains(where: { $0.id == cur }) {
                                    Text(IRKeys.def(cur)?.label ?? cur).tag(String?.some(cur))
                                }
                            }
                        }
                        Section {
                            Toggle("Set volume", isOn: $useVolume).tint(Theme.accent)
                            if useVolume {
                                HStack {
                                    Slider(value: Binding(get: { Double(preset.volume ?? 20) }, set: { preset.volume = Int($0) }), in: 0...100, step: 1)
                                    Text("\(preset.volume ?? 20)").monospacedDigit().frame(width: 34)
                                }
                            }
                        } footer: {
                            Text("Exact volume needs Wi-Fi.")
                        }
                        Section("Buttons to press") {
                            ForEach(Self.featureKeys, id: \.self) { k in
                                Toggle(IRKeys.def(k)?.label ?? k, isOn: Binding(
                                    get: { preset.keys.contains(k) },
                                    set: { on in
                                        preset.keys.removeAll { $0 == k }
                                        if on { preset.keys.append(k) }
                                    }))
                                .tint(Theme.accent)
                            }
                        }
                        Section {
                            Button {
                                Task {
                                    capturing = true
                                    defer { capturing = false }
                                    do {
                                        preset = try await Presets.capture(into: preset)
                                        useVolume = preset.volume != nil
                                    } catch {
                                        store.show(error.localizedDescription)
                                    }
                                }
                            } label: {
                                HStack { Text("Capture how the bar sounds now"); Spacer(); if capturing { ProgressView() } }
                            }
                            .disabled(!store.bar.hasWiFi || capturing)
                            ForEach(preset.settings, id: \.path) { s in
                                LabeledContent(s.name, value: s.value.display)
                            }
                            .onDelete { preset.settings.remove(atOffsets: $0) }
                        } header: {
                            Text("Exact settings")
                        } footer: {
                            Text("Saves input, volume and every sound setting the bar reports (EQ, levels, modes). Swipe to drop ones you don't want.")
                        }
                    }
                    if store.presets.contains(where: { $0.id == preset.id }) {
                        Section {
                            Button("Delete preset", role: .destructive) { store.deletePreset(preset.id); dismiss() }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !useVolume { preset.volume = nil }
                        store.savePreset(preset)
                        dismiss()
                    }
                }
            }
            .onAppear { useVolume = preset.volume != nil }
        }
    }
}
