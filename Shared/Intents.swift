import Foundation
import AppIntents
import WidgetKit

// MARK: - Entities

struct PresetEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sound Bar Preset"
    static var defaultQuery = PresetQuery()

    var id: String
    var name: String
    var icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }
    init(id: String, name: String, icon: String) { self.id = id; self.name = name; self.icon = icon }
    init(_ p: BarPreset) { id = p.id; name = p.name; icon = p.icon }
}

struct PresetQuery: EntityStringQuery {
    private func everything() -> [PresetEntity] { PresetStore.load().map(PresetEntity.init) }
    func entities(for identifiers: [String]) async throws -> [PresetEntity] { everything().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [PresetEntity] {
        let q = string.lowercased()
        return everything().filter { $0.name.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [PresetEntity] { everything() }
}

/// An input: the bar's own SmartCast names when it has been seen on Wi-Fi, otherwise the remote's input keys.
struct InputEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sound Bar Input"
    static var defaultQuery = InputQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct InputQuery: EntityStringQuery {
    static func everything() -> [InputEntity] {
        let known = InputCache.load()
        if !known.isEmpty { return known.map { InputEntity(id: $0.name, name: $0.label) } }
        return IRKeys.all.filter { $0.group == .inputs && $0.id != "input" }.map { InputEntity(id: $0.id, name: $0.label) }
    }
    func entities(for identifiers: [String]) async throws -> [InputEntity] {
        let all = Self.everything()
        return identifiers.map { id in all.first { $0.id == id } ?? InputEntity(id: id, name: IRKeys.def(id)?.label ?? id) }
    }
    func entities(matching string: String) async throws -> [InputEntity] {
        let q = string.lowercased()
        return Self.everything().filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [InputEntity] { Self.everything() }
}

struct ButtonEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sound Bar Button"
    static var defaultQuery = ButtonQuery()

    var id: String
    var name: String
    var symbol: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: symbol.map { DisplayRepresentation.Image(systemName: $0) })
    }
    init(_ d: IRKeyDef) { id = d.id; name = d.label; symbol = d.symbol }
}

struct ButtonQuery: EntityStringQuery {
    private func everything() -> [ButtonEntity] { IRKeys.all.map(ButtonEntity.init) }
    func entities(for identifiers: [String]) async throws -> [ButtonEntity] { everything().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [ButtonEntity] {
        let q = string.lowercased()
        return everything().filter { $0.name.lowercased().contains(q) }
    }
    func suggestedEntities() async throws -> [ButtonEntity] { everything() }
}

/// The bar's inputs as last read over Wi-Fi, so Siri and the widget can offer them.
struct CachedInput: Codable, Hashable {
    var name: String     // what the bar wants back when switching
    var label: String    // what to show
}

enum InputCache {
    static func load() -> [CachedInput] { AppGroup.read([CachedInput].self, "inputs.json") ?? [] }
    static func save(_ l: [CachedInput]) { AppGroup.write(l, "inputs.json") }
}

// MARK: - Intents

private func reload() { WidgetCenter.shared.reloadAllTimelines() }

struct SoundBarPowerIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set Sound Bar Power"
    static var description = IntentDescription("Turns the Vizio sound bar on or off, over Wi-Fi or through the IR blaster.")

    @Parameter(title: "On")
    var on: Bool

    init() {}
    init(on: Bool) { self.on = on }

    static var parameterSummary: some ParameterSummary { Summary("Turn the sound bar \(\.$on)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await Bar.perform(.power(on))
        reload()
        if !on { Donate.off() }
        return .result(dialog: IntentDialog(stringLiteral: on ? "Sound bar on." : "Sound bar off."))
    }
}

struct SoundBarOffIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Turn Sound Bar Off"
    static var description = IntentDescription("Turns the Vizio sound bar off.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await Bar.perform(.power(false))
        reload()
        Donate.off()
        return .result(dialog: "Sound bar off.")
    }
}

struct SoundBarOnIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Turn Sound Bar On"
    static var description = IntentDescription("Turns the Vizio sound bar on.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await Bar.perform(.power(true))
        reload()
        return .result(dialog: "Sound bar on.")
    }
}

struct ToggleSoundBarIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Toggle Sound Bar Power"
    static var description = IntentDescription("Turns the sound bar on if it's off, off if it's on.")
    func perform() async throws -> some IntentResult {
        try await Bar.perform(.power(nil))
        reload()
        return .result()
    }
}

struct VolumeUpIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Sound Bar Volume Up"
    static var description = IntentDescription("Turns the sound bar up by a few steps.")

    @Parameter(title: "Steps", default: 2, inclusiveRange: (1, 20))
    var steps: Int

    init() {}
    init(steps: Int) { self.steps = steps }

    static var parameterSummary: some ParameterSummary { Summary("Turn the sound bar up \(\.$steps) steps") }

    func perform() async throws -> some IntentResult {
        try await Bar.perform(.volumeUp(steps))
        reload()
        return .result()
    }
}

struct VolumeDownIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Sound Bar Volume Down"
    static var description = IntentDescription("Turns the sound bar down by a few steps.")

    @Parameter(title: "Steps", default: 2, inclusiveRange: (1, 20))
    var steps: Int

    init() {}
    init(steps: Int) { self.steps = steps }

    static var parameterSummary: some ParameterSummary { Summary("Turn the sound bar down \(\.$steps) steps") }

    func perform() async throws -> some IntentResult {
        try await Bar.perform(.volumeDown(steps))
        reload()
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set Sound Bar Volume"
    static var description = IntentDescription("Sets the sound bar to an exact volume (needs the bar on Wi-Fi).")

    @Parameter(title: "Volume", default: 20, inclusiveRange: (0, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary { Summary("Set the sound bar volume to \(\.$level)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await Bar.perform(.setVolume(level))
        reload()
        return .result(dialog: "Volume \(level).")
    }
}

struct MuteIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Mute Sound Bar"
    static var description = IntentDescription("Mutes or unmutes the sound bar.")
    func perform() async throws -> some IntentResult {
        try await Bar.perform(.mute(nil))
        reload()
        return .result()
    }
}

struct SetInputIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Set Sound Bar Input"
    static var description = IntentDescription("Switches the sound bar to an input (TV, Bluetooth, optical…).")

    @Parameter(title: "Input")
    var input: InputEntity

    init() {}
    init(input: InputEntity) { self.input = input }

    static var parameterSummary: some ParameterSummary { Summary("Switch the sound bar to \(\.$input)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await Bar.perform(.input(input.id))
        reload()
        return .result(dialog: "\(input.name).")
    }
}

struct RunPresetIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Run Sound Bar Preset"
    static var description = IntentDescription("Runs one of your Subwave presets.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    init() {}
    init(preset: PresetEntity) { self.preset = preset }

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$preset)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let p = PresetStore.load().first(where: { $0.id == preset.id }) else {
            throw BarError("That preset doesn't exist anymore.")
        }
        try await Presets.run(p)
        reload()
        Donate.preset(p)
        return .result(dialog: "\(p.name).")
    }
}

struct PressButtonIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Press Sound Bar Button"
    static var description = IntentDescription("Presses any button from the sound bar's remote: sound modes, night mode, bass, Bluetooth pairing and more.")

    @Parameter(title: "Button")
    var button: ButtonEntity

    init() {}
    init(button: ButtonEntity) { self.button = button }

    static var parameterSummary: some ParameterSummary { Summary("Press \(\.$button) on the sound bar") }

    func perform() async throws -> some IntentResult {
        try await Bar.perform(.irKey(button.id))
        reload()
        return .result()
    }
}

struct PlayPauseIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Sound Bar Play/Pause"
    static var description = IntentDescription("Plays or pauses whatever's playing on the sound bar (Bluetooth, USB, Cast).")
    func perform() async throws -> some IntentResult {
        try await Bar.perform(.playPause)
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Sound Bar Next Track"
    static var description = IntentDescription("Skips to the next track (IR).")
    func perform() async throws -> some IntentResult {
        try await Bar.perform(.next)
        return .result()
    }
}

struct GetSoundBarPowerIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Is the Sound Bar On"
    static var description = IntentDescription("Asks the sound bar over Wi-Fi whether it's on. Returns true or false.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard BarConfig.stored.hasWiFi else { throw BarError("Add the sound bar's Wi-Fi address in Subwave first.") }
        let s = await Bar.refresh()
        reload()
        return .result(value: s.power ?? false)
    }
}

/// For Shortcuts automations (time of day, Sleep focus, leaving home): only acts if the TV is off.
struct SoundBarOffIfTVOffIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Sound Bar Off If TV Is Off"
    static var description = IntentDescription("Turns the sound bar off, unless the Sony TV is on.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if TVConfig.stored.isSet, await TV.isOn() {
            return .result(dialog: "TV is on, leaving the sound bar.")
        }
        try await Bar.perform(.power(false))
        reload()
        return .result(dialog: "Sound bar off.")
    }
}

struct RefreshBarIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Sound Bar"
    static var isDiscoverable: Bool = false
    func perform() async throws -> some IntentResult {
        await Bar.refresh()
        reload()
        return .result()
    }
}

// MARK: - Control Center (iOS 18)

@available(iOS 18.0, *)
struct BarPowerSwitchIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Sound Bar Power"
    static var isDiscoverable: Bool = false

    @Parameter(title: "On")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        try await Bar.perform(.power(value))
        return .result()
    }
}

@available(iOS 18.0, *)
struct BarMuteSwitchIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Sound Bar Mute"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Muted")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        try await Bar.perform(.mute(value))
        return .result()
    }
}

@available(iOS 18.0, *)
struct PresetControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Preset"

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    init() {}
}

@available(iOS 18.0, *)
struct PresetButtonIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Preset"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    init() {}
    init(preset: PresetEntity?) { self.preset = preset }

    func perform() async throws -> some IntentResult {
        guard let id = preset?.id, let p = PresetStore.load().first(where: { $0.id == id }) else {
            throw BarError("Pick a preset for this control.")
        }
        try await Presets.run(p)
        return .result()
    }
}

// MARK: - Learning

/// Tells Siri when you switch the bar off or run presets, so it can suggest them at your usual times.
enum Donate {
    static func off() {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: SoundBarOffIntent()) }
    }
    static func preset(_ p: BarPreset) {
        Task { _ = try? await IntentDonationManager.shared.donate(intent: RunPresetIntent(preset: PresetEntity(p))) }
    }
}
