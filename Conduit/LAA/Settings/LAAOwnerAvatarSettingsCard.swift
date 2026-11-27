#if LAA_BUILD
import LAAKit
import SwiftUI

struct LAAOwnerAvatarSettingsCard: View {
    @EnvironmentObject private var bridge: LAABridgeSession

    var body: some View {
        LAAOwnerProfileSettingsCard { [bridge] data in
            try await LAAOwnerAvatarStore.shared.mirror(data, bridge: bridge)
        }
        .padding(LAASpacing.x4)
    }
}
#endif
