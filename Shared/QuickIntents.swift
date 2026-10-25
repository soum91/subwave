import AppIntents
import Foundation
struct BarButtonWidgetConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Soundbar button"
    @Parameter(title: "Button") var button: ButtonEntity?
}
@available(iOS 18.0, *) struct BarButtonControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Soundbar button"
    @Parameter(title: "Button") var button: ButtonEntity?
}
struct FavouriteBarButtonIntent: AppIntent {
    static var title: LocalizedStringResource = "Press Soundbar Button"
    @Parameter(title: "Button") var button: ButtonEntity?
    init() {}
    init(_ button: ButtonEntity?) { self.button = button }
    func perform() async throws -> some IntentResult {
        guard let button else { throw NSError(domain: "SubwaveControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a soundbar button first."]) }
        _ = try await PressButtonIntent(button: button).perform()
        return .result()
    }
}
