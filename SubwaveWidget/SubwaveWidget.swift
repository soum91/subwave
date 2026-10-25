import WidgetKit
import SwiftUI
import AppIntents

@main
struct SubwaveWidgets: WidgetBundle {
    var body: some Widget {
        FavouriteBarButtonWidget()
        BarRemoteControl()

        BarWidget()
        BarPowerControl()
        BarMuteControl()
        VolumeUpControl()
        VolumeDownControl()
        PresetControl()
    }
}

private let accent = Color(red: 0.32, green: 0.84, blue: 0.86)

// MARK: - Timeline

struct BarEntry: TimelineEntry {
    let date: Date
    let state: BarState
    let name: String
    let setUp: Bool
    let shared: Bool
    let presets: [BarPreset]

    var isOn: Bool { state.power == true }

    static func make() -> BarEntry {
        let cfg = BarConfig.stored
        return BarEntry(date: .now, state: .stored, name: cfg.name, setUp: cfg.hasWiFi || BlasterConfig.stored.isReady,
                        shared: AppGroup.isShared, presets: PresetStore.load())
    }

    static let preview = BarEntry(date: .now, state: BarState(power: true, volume: 24, muted: false, input: "TV (ARC)"),
                                  name: "Sound bar", setUp: true, shared: true, presets: BarPreset.defaults)
}

struct BarProvider: TimelineProvider {
    func placeholder(in context: Context) -> BarEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (BarEntry) -> Void) {
        let e = BarEntry.make()
        completion(context.isPreview && !e.setUp ? .preview : e)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BarEntry>) -> Void) {
        Task {
            await Bar.refresh()
            completion(Timeline(entries: [.make()], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - Widget

struct BarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SubwaveBar", provider: BarProvider()) { entry in
            BarWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBG(entry: entry) }
        }
        .configurationDisplayName("Sound bar")
        .description("Power, volume, presets, and a full remote in the large size.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

extension WidgetFamily {
    var isAccessory: Bool { self == .accessoryCircular || self == .accessoryRectangular || self == .accessoryInline }
}

struct WidgetBG: View {
    let entry: BarEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family.isAccessory {
            Color.clear
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.10), Color(red: 0.01, green: 0.02, blue: 0.03)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [accent.opacity(entry.isOn ? 0.35 : 0.06), .clear], center: .topLeading, startRadius: 5, endRadius: 260)
            }
        }
    }
}

struct BarWidgetView: View {
    let entry: BarEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.setUp {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "hifispeaker").font(.title2)
                Spacer()
                Text(entry.shared ? "Open Subwave to set up the sound bar." : "Widget can't see Subwave's data. Reinstall with app extensions kept.")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            switch family {
            case .systemMedium: medium
            case .systemLarge: large
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline:
                Label(entry.isOn ? "Bar \(entry.state.volume.map { "vol \($0)" } ?? "on")" : "Bar off", systemImage: "hifispeaker.fill")
            default: small
            }
        }
    }

    private var statusLine: String {
        guard entry.isOn else { return entry.state.power == false ? "Standby" : "Tap to toggle" }
        return entry.state.muted == true ? "Muted" : (entry.state.input ?? "On")
    }

    private func roundKey(_ symbol: String, _ intent: some AppIntent, filled: Bool = false, size: CGFloat = 36) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .frame(width: size, height: size)
                .background(filled ? accent : Color.white.opacity(0.12), in: Circle())
                .foregroundStyle(filled ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.isOn ? (entry.state.volume.map { "\($0)" } ?? "On") : "Off")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(entry.state.muted == true ? .white.opacity(0.4) : .white)
                    Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                roundKey("power", ToggleSoundBarIntent(), filled: entry.isOn, size: 34)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                roundKey("minus", VolumeDownIntent(steps: 2))
                roundKey(entry.state.muted == true ? "speaker.slash.fill" : "speaker.fill", MuteIntent())
                roundKey("plus", VolumeUpIntent(steps: 2))
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(entry.isOn ? (entry.state.volume.map { "\($0)" } ?? "On") : "Off")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(entry.state.muted == true ? .white.opacity(0.4) : .white)
                Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    roundKey("power", ToggleSoundBarIntent(), filled: entry.isOn)
                    roundKey("minus", VolumeDownIntent(steps: 2))
                    roundKey("plus", VolumeUpIntent(steps: 2))
                    roundKey(entry.state.muted == true ? "speaker.slash.fill" : "speaker.fill", MuteIntent())
                }
            }
            VStack(spacing: 6) {
                ForEach(entry.presets.prefix(4)) { p in
                    Button(intent: RunPresetIntent(preset: PresetEntity(p))) {
                        Label(p.name, systemImage: p.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 112)
        }
    }

    private func press(_ id: String) -> some View {
        let d = IRKeys.def(id)
        return Button(intent: PressButtonIntent(button: d.map(ButtonEntity.init) ?? ButtonEntity(IRKeys.all[0]))) {
            VStack(spacing: 3) {
                Image(systemName: d?.symbol ?? "circle").font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
                Text(d?.label ?? id).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    /// A remote: power, volume rocker, mute, transport, sound modes, inputs.
    private var large: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Text(statusLine).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer()
                roundKey("power", ToggleSoundBarIntent(), filled: entry.isOn, size: 40)
            }
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Button(intent: VolumeUpIntent(steps: 2)) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .bold)).frame(width: 52, height: 40)
                    }.buttonStyle(.plain)
                    Text(entry.isOn ? (entry.state.volume.map { "\($0)" } ?? "VOL") : "VOL")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(entry.state.muted == true ? .white.opacity(0.4) : .white)
                    Button(intent: VolumeDownIntent(steps: 2)) {
                        Image(systemName: "minus").font(.system(size: 16, weight: .bold)).frame(width: 52, height: 40)
                    }.buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.1), in: Capsule())
                VStack(spacing: 10) {
                    HStack {
                        roundKey(entry.state.muted == true ? "speaker.slash.fill" : "speaker.fill", MuteIntent(), size: 38)
                        Spacer()
                        roundKey("backward.fill", PressButtonIntent(button: ButtonEntity(IRKeys.def("prev")!)), size: 38)
                        Spacer()
                        roundKey("playpause.fill", PlayPauseIntent(), size: 38)
                        Spacer()
                        roundKey("forward.fill", NextTrackIntent(), size: 38)
                    }
                    HStack {
                        press("eqMovie")
                        press("eqMusic")
                        press("nightOn")
                        press("dialogUp")
                    }
                }
            }
            HStack {
                press("hdmiArc")
                press("bluetooth")
                press("optical")
                press("btPair")
            }
            HStack(spacing: 6) {
                ForEach(entry.presets.prefix(3)) { p in
                    Button(intent: RunPresetIntent(preset: PresetEntity(p))) {
                        Label(p.name, systemImage: p.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var circular: some View {
        Button(intent: ToggleSoundBarIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: entry.isOn ? "hifispeaker.fill" : "hifispeaker").font(.system(size: 16, weight: .semibold))
                    Text(entry.isOn ? (entry.state.volume.map { "\($0)" } ?? "on") : "off").font(.system(size: 12, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(entry.isOn ? "Volume \(entry.state.volume.map { "\($0)" } ?? "–")" : "Sound bar off", systemImage: "hifispeaker.fill")
                .font(.headline)
            Text(statusLine).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Control Center

@available(iOS 18.0, *)
struct BarPowerProvider: ControlValueProvider {
    var previewValue: Bool { true }
    func currentValue() async throws -> Bool {
        if BarConfig.stored.hasWiFi { return await Bar.refresh().power ?? false }
        return BarState.stored.power ?? false
    }
}

@available(iOS 18.0, *)
struct BarPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.subwave.power", provider: BarPowerProvider()) { on in
            ControlWidgetToggle("Sound bar", isOn: on, action: BarPowerSwitchIntent()) { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "hifispeaker.fill" : "hifispeaker")
            }
            .tint(.teal)
        }
        .displayName("Sound bar power")
        .description("Turn the Vizio sound bar on and off.")
    }
}

@available(iOS 18.0, *)
struct BarMuteProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { BarState.stored.muted ?? false }
}

@available(iOS 18.0, *)
struct BarMuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.subwave.mute", provider: BarMuteProvider()) { muted in
            ControlWidgetToggle("Mute sound bar", isOn: muted, action: BarMuteSwitchIntent()) { isMuted in
                Label(isMuted ? "Muted" : "Sound on", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .tint(.red)
        }
        .displayName("Sound bar mute")
        .description("Mute and unmute the sound bar.")
    }
}

@available(iOS 18.0, *)
struct VolumeUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.subwave.volup") {
            ControlWidgetButton(action: VolumeUpIntent(steps: 2)) {
                Label("Bar volume up", systemImage: "speaker.plus.fill")
            }
            .tint(.teal)
        }
        .displayName("Sound bar volume up")
        .description("Two steps louder.")
    }
}

@available(iOS 18.0, *)
struct VolumeDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.subwave.voldown") {
            ControlWidgetButton(action: VolumeDownIntent(steps: 2)) {
                Label("Bar volume down", systemImage: "speaker.minus.fill")
            }
            .tint(.teal)
        }
        .displayName("Sound bar volume down")
        .description("Two steps quieter.")
    }
}

struct PresetControlValue {
    var name: String
    var icon: String
    var entity: PresetEntity?
}

@available(iOS 18.0, *)
struct PresetControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: PresetControlConfig) -> PresetControlValue {
        PresetControlValue(name: configuration.preset?.name ?? "Preset", icon: configuration.preset?.icon ?? "sparkles", entity: configuration.preset)
    }

    func currentValue(configuration: PresetControlConfig) async throws -> PresetControlValue {
        if let e = configuration.preset, let p = PresetStore.load().first(where: { $0.id == e.id }) {
            return PresetControlValue(name: p.name, icon: p.icon, entity: PresetEntity(p))
        }
        return PresetControlValue(name: configuration.preset?.name ?? "Pick a preset", icon: "sparkles", entity: configuration.preset)
    }
}

@available(iOS 18.0, *)
struct PresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soum91.subwave.preset", provider: PresetControlProvider()) { value in
            ControlWidgetButton(action: PresetButtonIntent(preset: value.entity)) {
                Label(value.name, systemImage: value.icon)
            }
            .tint(.teal)
        }
        .displayName("Sound bar preset")
        .description("Run one of your Subwave presets.")
    }
}
