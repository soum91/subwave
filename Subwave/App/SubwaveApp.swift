import SwiftUI
import BackgroundTasks
import WidgetKit
import AppIntents

@main
struct SubwaveApp: App {
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase
    static let refreshID = "com.soum91.subwave.refresh"

    init() {
        SubwaveShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .background(VolumeHUDHider().frame(width: 1, height: 1).opacity(0.01))
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: phase, initial: true) { _, newPhase in
            switch newPhase {
            case .active:
                store.startPolling()
                if store.blaster.isReady, !store.blasterState.isConnected { store.connectBlaster() }
                store.updateVolumeButtons(active: true)
                Task {
                    await BridgeSync.pushIfChanged()
                    await store.refreshBridge()
                }
            case .inactive:
                store.updateVolumeButtons(active: false)
            case .background:
                store.updateVolumeButtons(active: false)
                store.stopPolling()
                Task { await IRSender.shared.drop() }
                Self.scheduleRefresh()
                WidgetCenter.shared.reloadAllTimelines()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshID)) {
            Self.scheduleRefresh()
            await Bar.refresh()
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}

/// Siri phrases. These work with no setup: "Hey Siri, sound bar off in Subwave".
struct SubwaveShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleSoundBarIntent(), phrases: [
            "Toggle sound bar power in \(.applicationName)",
            "Switch my sound bar with \(.applicationName)",
        ], shortTitle: "Sound Bar Switch", systemImageName: "hifispeaker.fill")
        AppShortcut(intent: SoundBarOffIntent(), phrases: [
            "Sound bar off in \(.applicationName)",
            "Turn off the sound bar in \(.applicationName)",
            "\(.applicationName) off",
        ], shortTitle: "Sound Bar Off", systemImageName: "power")
        AppShortcut(intent: SoundBarOnIntent(), phrases: [
            "Sound bar on in \(.applicationName)",
            "Turn on the sound bar in \(.applicationName)",
            "\(.applicationName) on",
        ], shortTitle: "Sound Bar On", systemImageName: "hifispeaker.fill")
        AppShortcut(intent: VolumeUpIntent(), phrases: [
            "Turn it up in \(.applicationName)",
            "\(.applicationName) louder",
        ], shortTitle: "Volume Up", systemImageName: "speaker.plus.fill")
        AppShortcut(intent: VolumeDownIntent(), phrases: [
            "Turn it down in \(.applicationName)",
            "\(.applicationName) quieter",
        ], shortTitle: "Volume Down", systemImageName: "speaker.minus.fill")
        AppShortcut(intent: MuteIntent(), phrases: [
            "Mute \(.applicationName)",
            "Mute the sound bar in \(.applicationName)",
        ], shortTitle: "Mute", systemImageName: "speaker.slash.fill")
        AppShortcut(intent: RunPresetIntent(), phrases: [
            "\(.applicationName) \(\.$preset)",
            "Run \(\.$preset) in \(.applicationName)",
            "Set \(.applicationName) to \(\.$preset)",
        ], shortTitle: "Run Preset", systemImageName: "sparkles")
        AppShortcut(intent: SetInputIntent(), phrases: [
            "Switch \(.applicationName) to \(\.$input)",
            "\(.applicationName) input \(\.$input)",
        ], shortTitle: "Set Input", systemImageName: "rectangle.portrait.and.arrow.forward")
        AppShortcut(intent: SoundBarOffIfTVOffIntent(), phrases: [
            "Bedtime in \(.applicationName)",
        ], shortTitle: "Off If TV Off", systemImageName: "tv.slash")
    }
}
