import SwiftUI
import WidgetKit

// Read-only Lock Screen status, built exactly like DewPoint's 1x1 temperature widget,
// the one Lock Screen widget that renders on iOS 27 beta 4 with sideloaded builds:
// static configuration, cached data only (no network in the timeline), no buttons,
// no accessory background. Tapping it opens the app.
struct SubwaveLockEntry: TimelineEntry {
    var date: Date
    var state: BarState
    var name: String
    var icon: String { state.power == true ? "hifispeaker.fill" : "hifispeaker" }
    var short: String { state.power == nil ? "--" : (state.power == true ? (state.volume.map { String($0) } ?? "On") : "Off") }
    var title: String { name }
    var headline: String { state.power == nil ? "Open Subwave" : (state.power == true ? (state.input ?? "On") : "Off") }
    var detail: String { state.power == true ? (state.volume.map { "Volume \($0)" + (state.muted == true ? " · muted" : "") } ?? "") : "" }
    static func make() -> SubwaveLockEntry { .init(date: .now, state: .stored, name: BarConfig.stored.name) }
}

struct SubwaveLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> SubwaveLockEntry { SubwaveLockEntry.make() }
    func getSnapshot(in context: Context, completion: @escaping (SubwaveLockEntry) -> Void) { completion(SubwaveLockEntry.make()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SubwaveLockEntry>) -> Void) {
        completion(Timeline(entries: [SubwaveLockEntry.make()], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct SubwaveLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SubwaveLockStatusV1", provider: SubwaveLockProvider()) { entry in
            SubwaveLockView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Sound bar status")
        .description("Sound bar power, input and volume. Tap to open Subwave.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct SubwaveLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SubwaveLockEntry

    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 1) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(entry.short)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: entry.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.caption2).lineLimit(1)
                        Text(entry.headline).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption2).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
