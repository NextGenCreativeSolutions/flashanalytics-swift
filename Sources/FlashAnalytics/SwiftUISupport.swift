#if canImport(SwiftUI)
import SwiftUI

@available(iOS 15.0, macOS 12.0, *)
public extension View {
    func flashAnalyticsScreen(
        _ analytics: FlashAnalytics,
        path: String,
        properties: [String: Any] = [:]
    ) -> some View {
        modifier(FlashAnalyticsScreenModifier(analytics: analytics, path: path, properties: properties))
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct FlashAnalyticsScreenModifier: ViewModifier {
    let analytics: FlashAnalytics
    let path: String
    let properties: [String: Any]

    func body(content: Content) -> some View {
        content.onAppear {
            analytics.pageView(path, properties: properties)
        }
    }
}
#endif
