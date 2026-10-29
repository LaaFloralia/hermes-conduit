#if LAA_BUILD
import Foundation

/// Presentation states for the future Bridge screens. No pairing record or
/// fetch is implemented here, so production always reports not paired.
enum LAAScreenState {
    case bridgeNotPaired, loading, empty, failed

    static var current: LAAScreenState {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-laa-state"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "loading": return .loading
            case "empty": return .empty
            case "failed": return .failed
            default: break
            }
        }
        #endif
        return .bridgeNotPaired
    }
}
#endif
