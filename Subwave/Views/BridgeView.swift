import SwiftUI

/// "Bar off when the TV goes off", run by the Afterglow ESP32 bridge (the only always-on thing in the house).
struct BridgeView: View {
    @EnvironmentObject var store: Store
    @StateObject private var finder = BridgeFinder()
    @State private var manual = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            Theme.background()
            List {
                if !store.bridge.isPaired {
                    pairSection
                } else {
                    statusSection
                    rulesSection
                    Section {
                        Button {
                            Task { busy = true; message = await BridgeSync.pushIfChanged(force: true); busy = false; await store.refreshBridge() }
                        } label: { HStack { Text("Send to bridge now"); Spacer(); if busy { ProgressView() } } }
                        Button("Test: bridge turns the bar off") { test(false) }
                        Button("Test: bridge turns the bar on") { test(true) }
                        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    }
                    Section { Button("Unlink bridge", role: .destructive) { store.forgetBridge() } }
                }
                Section {
                    Text("No bridge? Shortcuts › Automation › e.g. Time of Day or Sleep Focus › **Sound Bar Off If TV Is Off**. Or just say \"Hey Siri, bedtime in Subwave\".")
                        .font(.callout).foregroundStyle(.secondary)
                } header: {
                    Text("Without the bridge")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Follow the TV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !store.bridge.isPaired { finder.start() } else { Task { await store.refreshBridge() } } }
        .onDisappear {
            finder.stop()
            Task { await BridgeSync.pushIfChanged() }
        }
    }

    private var pairSection: some View {
        Group {
            Section {
                Text("iPhones can't run automations in the background and you have no Home hub, so this runs on the Afterglow bridge (the ESP32 that already turns the lights off with the TV). It watches the Sony TV every 4 s and switches the bar off over Wi-Fi, or with the IR blaster if the bar isn't on Wi-Fi. It also puts a **Sound Bar** switch in Apple Home.")
                    .font(.callout)
            }
            Section {
                if finder.found.isEmpty {
                    HStack {
                        if finder.searching { ProgressView().padding(.trailing, 6) }
                        Text(finder.searching ? "Looking for the bridge…" : "Not found. Is it powered and on Wi-Fi?").foregroundStyle(.secondary)
                    }
                }
                ForEach(finder.found, id: \.host) { b in
                    Button { pair(b.host, b.port) } label: {
                        HStack {
                            Image(systemName: "cpu").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading) {
                                Text(b.name).foregroundStyle(.white)
                                Text(b.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                }
                HStack {
                    TextField("Bridge IP", text: $manual).keyboardType(.decimalPad)
                    Button("Pair") { pair(manual, 8080) }.disabled(manual.isEmpty || busy)
                }
                if let message { Text(message).font(.callout).foregroundStyle(Theme.danger) }
            } header: {
                HStack { Text("Afterglow bridge"); Spacer(); Button("Search again") { finder.start() }.font(.caption) }
            } footer: {
                Text("Needs bridge firmware 1.1 or newer (Afterglow releases › firmware-latest, flash the -app.bin to keep your Home pairing). Subwave pairs separately from Afterglow; both can use the same bridge.")
            }
        }
    }

    private var statusSection: some View {
        Section("Bridge") {
            LabeledContent("Address", value: store.bridge.host)
            if let i = store.bridgeInfo {
                if let v = i.version { LabeledContent("Firmware", value: v) }
                LabeledContent("TV", value: i.tv?.state ?? "–")
                LabeledContent("Sound bar", value: i.bar?.state ?? "–")
                ForEach(Array((i.bar?.events ?? []).suffix(6).reversed()), id: \.self) { e in
                    Text(e).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } else {
                Text("Not answering right now.").foregroundStyle(.secondary)
            }
            if let t = store.bridge.lastPush {
                LabeledContent("Last sent", value: t.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var rulesSection: some View {
        Group {
            Section {
                if !store.tv.isSet {
                    Text("Set the TV's IP in Settings › Sony TV first (or in Afterglow, the bridge uses either).")
                        .font(.callout).foregroundStyle(Theme.danger)
                }
                Toggle("Bar off when the TV turns off", isOn: $store.auto.offEnabled).tint(Theme.accent)
                if store.auto.offEnabled {
                    Stepper("After \(store.auto.offDelay) s", value: $store.auto.offDelay, in: 0...600, step: 5)
                    Toggle("Only between", isOn: $store.auto.offWindow).tint(Theme.accent)
                    if store.auto.offWindow {
                        DatePicker("From", selection: timeBinding($store.auto.offFrom), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: timeBinding($store.auto.offTo), displayedComponents: .hourAndMinute)
                    }
                    if !store.bar.hasWiFi || store.bar.route == .ir {
                        Toggle("Use IR power toggle", isOn: $store.auto.irToggleWhenOff).tint(Theme.accent)
                    }
                }
            } header: {
                Text("TV off")
            } footer: {
                Text("Over Wi-Fi the bridge sends a real \"power off\", so it's safe even if the bar already followed the TV. Over IR the remote only has a power toggle: turn \"Use IR power toggle\" on only if the bar does NOT go off with the TV by itself (HDMI-CEC), otherwise it'd switch it back on.")
            }
            Section("TV on") {
                Toggle("Bar on when the TV turns on", isOn: $store.auto.onEnabled).tint(Theme.accent)
                if store.auto.onEnabled {
                    Toggle("Only between", isOn: $store.auto.onWindow).tint(Theme.accent)
                    if store.auto.onWindow {
                        DatePicker("From", selection: timeBinding($store.auto.onFrom), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: timeBinding($store.auto.onTo), displayedComponents: .hourAndMinute)
                    }
                }
            }
        }
    }

    private func pair(_ host: String, _ port: Int) {
        Task {
            busy = true
            message = await store.pairBridge(host: host.trimmingCharacters(in: .whitespaces), port: port)
            busy = false
            if store.bridge.isPaired { finder.stop(); await store.refreshBridge() }
        }
    }

    private func test(_ on: Bool) {
        Task {
            do {
                _ = await BridgeSync.pushIfChanged()
                let via = try await BridgeAPI.test(on: on, store.bridge)
                message = "Bridge sent it via \(via)."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
