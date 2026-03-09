import Foundation
import PostHog

enum Analytics {
    private static let apiKey = "phc_REPLACE_WITH_YOUR_KEY"
    private static let host = "https://us.i.posthog.com"

    static func setup() {
        let config = PostHogConfig(apiKey: apiKey, host: host)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        config.sendFeatureFlagsOnNewIdentity = false
        PostHogSDK.shared.setup(config)

        PostHogSDK.shared.capture("app_opened", properties: [
            "platform": "macos",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        ])
    }

    static func capture(_ event: String, properties: [String: Any] = [:]) {
        var props = properties
        props["platform"] = "macos"
        PostHogSDK.shared.capture(event, properties: props)
    }
}
