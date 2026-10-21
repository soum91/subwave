import SwiftUI
import UniformTypeIdentifiers

/// Every button on the Vizio remote. Taps go over Wi-Fi when the bar has a matching setting, IR otherwise.
/// Learn mode records a button from the real remote into the blaster.
struct IRRemoteView: View {
    @EnvironmentObject var store: Store
    @State private var learnMode = false
    @State private var importing = false
    @State private var irOnly = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10)]

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background(learnMode ? Color(red: 1, green: 0.4, blue: 0.4) : Theme.accent, strength: 0.18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RemoteFace(tap: tap)
                    SectionTitle(text: "Every button")
                    if learnMode {
                        Text("Learn mode: tap a button here, then press the same button on your Vizio remote, aimed at the blaster.")
                            .font(.callout)
                            .card()
                    } else if !store.blaster.isReady {
                        Text("No IR blaster set up, so these go over Wi-Fi where the bar has a matching setting. Set the blaster up in Settings for the rest.")
                            .font(.callout).foregroundStyle(.secondary)
                            .card()
                    }
                    ForEach(IRGroup.allCases) { g in
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(text: g.rawValue)
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(IRKeys.all.filter { $0.group == g }) { k in
                                    KeyButton(symbol: k.symbol, label: k.label, size: 56,
                                              tint: learnMode ? Color(red: 1, green: 0.55, blue: 0.5) : .white,
                                              badge: store.codes[k.id] != nil) {
                                        tap(k)
                                    }
                                    .contextMenu {
                                        if store.blaster.isReady {
                                            Button { store.startLearn(k.id) } label: { Label("Learn from remote", systemImage: "record.circle") }
                                            Button { store.testIR(k.id) } label: { Label("Send over IR", systemImage: "dot.radiowaves.right") }
                                        }
                                        if store.codes[k.id] != nil {
                                            Button(role: .destructive) { store.codes[k.id] = nil } label: {
                                                Label("Forget learned code", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text("A dot means the button was learned from your remote. Others use built-in Vizio codes (NEC, from the SB3651/V-series remotes); if one does nothing, long-press it and learn it.")
                        .font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            if let t = store.toast { Toast(text: t).padding(.bottom, 24) }
        }
        .navigationTitle("Remote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $learnMode) { Label("Learn mode", systemImage: "record.circle") }
                        .disabled(!store.blaster.isReady)
                    Toggle(isOn: $irOnly) { Label("Always send IR", systemImage: "dot.radiowaves.right") }
                        .disabled(!store.blaster.isReady)
                    Button { importing = true } label: { Label("Import from Redshift", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: learnMode ? "record.circle.fill" : "ellipsis.circle")
                        .foregroundStyle(learnMode ? Color(red: 1, green: 0.45, blue: 0.45) : Theme.accent)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            if case .success(let url) = r { store.importRedshift(from: url) }
        }
    }

    private func tap(_ k: IRKeyDef) {
        if learnMode {
            store.startLearn(k.id)
        } else if irOnly {
            store.testIR(k.id)
        } else {
            store.perform(.irKey(k.id))
        }
    }
}

struct LearnSheet: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            Theme.background(Color(red: 1, green: 0.4, blue: 0.4), strength: 0.2)
            VStack(spacing: 18) {
                if let s = store.learning {
                    Text("Learning \(s.label)").font(.title2.bold())
                    switch s.phase {
                    case .starting:
                        ProgressView("Putting the blaster in learn mode…")
                    case .waiting:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 44))
                            .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                            .symbolEffect(.variableColor.iterative)
                        Text("Point the Vizio remote at the blaster from 5 to 10 cm and press **\(s.label)** once.")
                            .multilineTextAlignment(.center)
                    case .captured(let n):
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                        Text("Got it (\(n) pulses).")
                        HStack {
                            Button("Test") { store.testIR(s.keyID) }.buttonStyle(.bordered)
                            Button("Learn again") { store.startLearn(s.keyID) }.buttonStyle(.bordered)
                            Button("Done") { store.endLearn() }.buttonStyle(.borderedProminent)
                        }
                    case .failed(let why):
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.danger)
                        Text(why).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        HStack {
                            Button("Try again") { store.startLearn(s.keyID) }.buttonStyle(.borderedProminent)
                            Button("Cancel") { store.endLearn() }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

/// The remote laid out like the real Vizio one: power and input up top, a volume rocker, transport, sound modes and inputs.
struct RemoteFace: View {
    @EnvironmentObject var store: Store
    let tap: (IRKeyDef) -> Void

    private func key(_ id: String, size: CGFloat = 54, filled: Bool = false) -> some View {
        let d = IRKeys.def(id)!
        return KeyButton(symbol: d.symbol, label: d.label, size: size, tint: filled ? Theme.accent : .white, filled: filled,
                         badge: store.codes[id] != nil) { tap(d) }
    }

    private func rocker(_ title: String, up: String, down: String) -> some View {
        VStack(spacing: 0) {
            RepeatButton(action: { tap(IRKeys.def(up)!) }) {
                Image(systemName: "plus").font(.system(size: 20, weight: .bold)).frame(width: 64, height: 62).contentShape(Rectangle())
            }
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 4)
            RepeatButton(action: { tap(IRKeys.def(down)!) }) {
                Image(systemName: "minus").font(.system(size: 20, weight: .bold)).frame(width: 64, height: 62).contentShape(Rectangle())
            }
        }
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke))
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                key("power", size: 60, filled: store.state.power == true)
                Spacer()
                if let v = store.state.volume, store.state.power == true {
                    Text("\(v)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(store.state.muted == true ? Theme.off : .white)
                }
                Spacer()
                key("btPair", size: 60)
            }
            HStack(alignment: .center) {
                rocker("VOL", up: "volUp", down: "volDown")
                Spacer()
                VStack(spacing: 18) {
                    key("mute", size: 58)
                    key("playPause", size: 58)
                }
                Spacer()
                rocker("BASS", up: "bassUp", down: "bassDown")
            }
            HStack {
                key("prev")
                Spacer()
                key("info")
                Spacer()
                key("next")
            }
            Divider().overlay(Theme.stroke)
            HStack {
                key("eqMovie")
                Spacer()
                key("eqMusic")
                Spacer()
                key("eqGame")
                Spacer()
                key("eqDirect")
            }
            HStack {
                key("nightOn")
                Spacer()
                key("dialogUp")
                Spacer()
                key("vxOn")
                Spacer()
                key("truVolOn")
            }
            Divider().overlay(Theme.stroke)
            HStack {
                key("hdmiArc")
                Spacer()
                key("bluetooth")
                Spacer()
                key("optical")
                Spacer()
                key("aux")
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}
