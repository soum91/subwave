import SwiftUI
import WidgetKit
import AppIntents
struct BarButtonEntry: TimelineEntry { var date: Date; var button: ButtonEntity? }
struct BarButtonProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BarButtonEntry { .init(date: .now, button: nil) }
    func snapshot(for configuration: BarButtonWidgetConfig, in context: Context) async -> BarButtonEntry { .init(date: .now, button: configuration.button) }
    func timeline(for configuration: BarButtonWidgetConfig, in context: Context) async -> Timeline<BarButtonEntry> {
        Timeline(entries: [.init(date: .now, button: configuration.button)], policy: .never)
    }
}
struct FavouriteBarButtonWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SubwaveFavouriteButton", intent: BarButtonWidgetConfig.self, provider: BarButtonProvider()) { entry in
            FavouriteBarButtonView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }.configurationDisplayName("Soundbar button").description("A selected input, Night command or any remote button.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

// A genuine 1-slot icon button: text labels can overflow the circular Lock Screen slot.
struct FavouriteBarButtonView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BarButtonEntry

    var body: some View {
        Button(intent: FavouriteBarButtonIntent(entry.button)) {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: entry.button?.symbol ?? "hifispeaker.fill")
                        .font(.system(size: 21, weight: .semibold))
                }
            } else {
                Label(entry.button?.name ?? "Choose a button",
                      systemImage: entry.button?.symbol ?? "hifispeaker.fill")
                    .font(.headline)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
    }
}

@available(iOS 18.0, *) struct BarRemoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soum91.subwave.button", intent: BarButtonControlConfig.self) { config in
            ControlWidgetButton(action: FavouriteBarButtonIntent(config.button)) {
                Label(config.button?.name ?? "Choose a button", systemImage: "hifispeaker.fill")
            }
        }.displayName("Soundbar button").description("Inputs, sound modes, Night on/off and every remote button.")
    }
}
