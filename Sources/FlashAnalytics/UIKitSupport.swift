#if canImport(UIKit)
import ObjectiveC.runtime
import UIKit

nonisolated(unsafe) private var trackerAssociationKey: UInt8 = 0

final class ControlTracker: NSObject {
    private weak var analytics: FlashAnalytics?
    private let eventName: String
    private let properties: [String: Any]

    init(analytics: FlashAnalytics, eventName: String, properties: [String: Any]) {
        self.analytics = analytics
        self.eventName = eventName
        self.properties = properties
    }

    @objc func handleControlEvent() {
        analytics?.track(eventName, properties: properties)
    }
}

enum ViewControllerSwizzler {
    nonisolated(unsafe) private static var isInstalled = false
    nonisolated(unsafe) private static weak var analytics: FlashAnalytics?

    static func install(analytics: FlashAnalytics) {
        self.analytics = analytics
        guard !isInstalled else { return }
        isInstalled = true

        let originalSelector = #selector(UIViewController.viewDidAppear(_:))
        let swizzledSelector = #selector(UIViewController.flashAnalytics_viewDidAppear(_:))

        guard
            let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector)
        else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    static func notify(viewController: UIViewController) {
        analytics?.autoTrackScreenViewController(viewController)
    }
}

extension UIViewController {
    @objc fileprivate func flashAnalytics_viewDidAppear(_ animated: Bool) {
        flashAnalytics_viewDidAppear(animated)
        ViewControllerSwizzler.notify(viewController: self)
    }
}

extension UIControl {
    var flashAnalyticsTrackers: NSMutableArray {
        if let existing = objc_getAssociatedObject(self, &trackerAssociationKey) as? NSMutableArray {
            return existing
        }

        let trackers = NSMutableArray()
        objc_setAssociatedObject(self, &trackerAssociationKey, trackers, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return trackers
    }
}
#endif
