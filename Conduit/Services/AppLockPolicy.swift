// App-owned saved sign-in lock only. OS Keychain access controls and server
// authentication remain independent of this policy.
struct AppLockPolicy: Equatable, Sendable {
    let isEnabled: Bool

    static let current: AppLockPolicy = {
        #if LAA_BUILD
        AppLockPolicy(isEnabled: false)
        #else
        AppLockPolicy(isEnabled: true)
        #endif
    }()

    func requiresUnlock(savedRequiresFaceID: Bool) -> Bool {
        isEnabled && savedRequiresFaceID
    }
}
