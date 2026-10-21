import SwiftUI

struct SetupView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Two ways in, use both if you can. Wi-Fi gives you everything (exact volume, all settings, state). IR wakes the bar from deep standby and keeps working when Vizio's Wi-Fi side doesn't.")
                            .foregroundStyle(.secondary)
                        NavigationLink { FindBarView() } label: {
                            step(1, "Sound bar on Wi-Fi", store.bar.hasWiFi ? "\(store.bar.name) at \(store.bar.host)" : "Find it on your network", done: store.bar.hasWiFi)
                        }
                        NavigationLink { BlasterSetupView() } label: {
                            step(2, "Tuya IR blaster", store.blaster.isReady ? "\(store.blaster.name ?? "Blaster") · \(store.blasterState.text)" : "The one Redshift uses", done: store.blaster.isReady)
                        }
                        if store.isSetUp {
                            Button { dismiss() } label: {
                                Text("Done").fontWeight(.semibold)
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                                    .foregroundStyle(.black)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Set up")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }

    private func step(_ n: Int, _ title: String, _ sub: String, done: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? Theme.accent : .white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.3))
        }
        .card()
    }
}

// MARK: - Find the bar

struct FindBarView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var finder = BarFinder()
    @State private var manual = ""
    @State private var busy: String?
    @State private var message: String?
    @State private var pin = ""

    var body: some View {
        ZStack {
            Theme.background()
            List {
                Section {
                    if finder.found.isEmpty {
                        HStack {
                            if finder.searching { ProgressView().padding(.trailing, 6) }
                            Text(finder.searching ? "Looking for Cast and SmartCast speakers…" : "Nothing found. Type the IP below (Vizio app or your router shows it).")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(finder.found) { f in
                        Button { Task { await pick(f.host, name: f.name, model: f.model) } } label: {
                            HStack {
                                Image(systemName: f.port != nil ? "hifispeaker.fill" : "dot.radiowaves.up.forward")
                                    .foregroundStyle(f.port != nil ? Theme.accent : .secondary)
                                    .frame(width: 26)
                                VStack(alignment: .leading) {
                                    Text(f.name).foregroundStyle(.white)
                                    Text([f.model, f.host, f.port.map { "SmartCast :\($0)" } ?? "Cast only"].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busy == f.host { ProgressView() }
                            }
                        }
                    }
                } header: {
                    HStack { Text("On your Wi-Fi"); Spacer(); Button("Search again") { finder.start() }.font(.caption) }
                }

                Section("By IP address") {
                    HStack {
                        TextField("192.168.1.50", text: $manual)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                        Button("Connect") { Task { await pick(manual, name: nil, model: nil) } }
                            .disabled(manual.isEmpty || busy != nil)
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(message.hasPrefix("Connected") ? Theme.accent : Theme.danger) }
                }

                if store.bar.hasWiFi {
                    Section {
                        Button("Ask the bar for a PIN") { Task { await store.startPair() } }
                        if store.pairing != nil {
                            HStack {
                                TextField("PIN shown/announced by the bar", text: $pin).keyboardType(.numberPad)
                                Button("Pair") { Task { await store.finishPair(pin: pin) } }.disabled(pin.isEmpty)
                            }
                        }
                    } header: {
                        Text("Pairing")
                    } footer: {
                        Text("Sound bars normally don't need this. Only use it if commands come back with a pairing error.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Sound bar")
        .onAppear { finder.start(); manual = store.bar.host }
        .onDisappear { finder.stop() }
    }

    private func pick(_ host: String, name: String?, model: String?) async {
        busy = host
        message = nil
        defer { busy = nil }
        if let err = await store.connectBar(host: host, name: name, model: model) {
            message = err
        } else {
            message = "Connected to \(store.bar.name)."
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        }
    }
}

// MARK: - IR blaster

struct BlasterSetupView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.blaster.hasKey {
                BlasterStatusView()
            } else if store.token != nil {
                BlasterPickerView()
            } else {
                LoginView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink("I have the key") { ManualKeyView() }
                        }
                    }
            }
        }
        .navigationTitle("IR blaster")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BlasterPickerView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            Theme.background()
            List {
                Section {
                    if store.loadingDevices {
                        HStack { ProgressView(); Text("Loading your devices…").foregroundStyle(.secondary) }
                    }
                    ForEach(store.devices) { d in
                        Button { store.choose(d) } label: {
                            HStack {
                                Image(systemName: d.isBlaster ? "dot.radiowaves.right" : "circle.dotted")
                                    .foregroundStyle(d.isBlaster ? Theme.accent : .secondary)
                                    .frame(width: 26)
                                VStack(alignment: .leading) {
                                    Text(d.name).foregroundStyle(.white)
                                    Text(d.productName.isEmpty ? d.category : d.productName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !d.online { Text("offline").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    Text("Pick the IR blaster")
                } footer: {
                    Text("Subwave saves its local key and talks to it over Wi-Fi from here on, same as Redshift.")
                }
                if let e = store.setupError { Section { Text(e).foregroundStyle(Theme.danger) } }
                Section { Button("Sign out of Smart Life", role: .destructive) { store.signOutCloud() } }
            }
            .scrollContentBackground(.hidden)
        }
        .task { if store.devices.isEmpty { await store.loadDevices() } }
    }
}

struct BlasterStatusView: View {
    @EnvironmentObject var store: Store
    @State private var host = ""

    var body: some View {
        ZStack {
            Theme.background()
            List {
                Section {
                    HStack {
                        Text(store.blaster.name ?? "IR blaster")
                        Spacer()
                        if store.blasterState.isBusy { ProgressView() }
                    }
                    Text(store.blasterState.text)
                        .font(.callout)
                        .foregroundStyle(store.blasterState.isConnected ? Theme.accent : (store.blasterState == .off ? .secondary : Theme.danger))
                    if let h = store.blaster.host { LabeledContent("IP", value: h) }
                    LabeledContent("Command format", value: store.blaster.format.title)
                }
                Section {
                    Button("Find it on Wi-Fi again") { store.findBlaster() }
                    HStack {
                        TextField("Blaster IP", text: $host).keyboardType(.decimalPad)
                        Button("Use") { store.setBlasterHost(host) }.disabled(host.isEmpty)
                    }
                    Button("Reconnect") { store.connectBlaster() }
                    Button("Test: send Power") { store.testIR("power") }
                }
                Section {
                    Picker("Command format", selection: Binding(get: { store.blaster.forced }, set: { store.blaster.forced = $0 })) {
                        Text("Automatic").tag(IRFormat?.none)
                        ForEach(IRFormat.allCases) { Text($0.title).tag(IRFormat?.some($0)) }
                    }
                    if store.token != nil {
                        Button("Refresh local key from Smart Life") { Task { await store.refreshKey() } }
                    }
                } footer: {
                    Text("Only change the format if buttons do nothing. Refresh the key if you re-paired the blaster in Smart Life.")
                }
                Section { Button("Forget blaster", role: .destructive) { store.forgetBlaster() } }
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            host = store.blaster.host ?? ""
            if store.blaster.isReady && !store.blasterState.isConnected && !store.blasterState.isBusy { store.connectBlaster() }
        }
    }
}

struct ManualKeyView: View {
    @EnvironmentObject var store: Store
    @State private var devId = ""
    @State private var key = ""
    @State private var host = ""

    var body: some View {
        ZStack {
            Theme.background()
            Form {
                Section {
                    TextField("Device ID", text: $devId).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Local key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("IP (optional, else it scans)", text: $host).keyboardType(.decimalPad)
                } footer: {
                    Text("From tinytuya, Home Assistant, or Redshift's settings.")
                }
                Button("Save") {
                    store.setBlaster(devId: devId.trimmingCharacters(in: .whitespaces), key: key.trimmingCharacters(in: .whitespaces),
                                     name: "IR blaster", host: host.trimmingCharacters(in: .whitespaces))
                }
                .disabled(devId.isEmpty || key.isEmpty)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Enter key")
    }
}
