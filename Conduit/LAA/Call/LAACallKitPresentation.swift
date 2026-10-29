#if LAA_BUILD
import CallKit
import Foundation

/// Presentation only: the existing provider continues to own call handling.
enum LAACallKitPresentation {
    static let localizedName = "LAA"

    static func configuration(bundle: Bundle = .main) -> CXProviderConfiguration {
        // iOS 14 and later use the app display name instead; keep the legacy
        // value as well for systems that still honor this initializer.
        let configuration = CXProviderConfiguration(localizedName: localizedName)
        if let url = bundle.url(forResource: "callkit-icon-template-120", withExtension: "png") {
            configuration.iconTemplateImageData = try? Data(contentsOf: url)
        }
        return configuration
    }

    static func callerName(profile: String, fallback: String) -> String {
        LAAStaff(profile: profile)?.name ?? fallback
    }

    static func outgoingUpdate(name: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.localizedCallerName = name
        return update
    }
}
#endif
