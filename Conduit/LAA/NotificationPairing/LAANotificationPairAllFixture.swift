#if LAA_BUILD && DEBUG
import SwiftUI

/// UI tests use the production controls with a fake dashboard and relay. They
/// never pair the real Mac's employee profiles to the simulator.
struct LAANotificationPairAllFixtureScreen: View {
    @StateObject private var model = LAANotificationPairAll()
    @StateObject private var fake = Fake()
    @State private var available = false

    private final class Fake: ObservableObject {
        let dashboardID = UUID()
        let installationID = "simulator"
        var failed = false

        func source() -> LAANotificationPairAll.Source {
            .init(dashboardID: dashboardID, installationID: installationID, canStart: { true }, isCurrent: { true }, profiles: {
                ["default", "laa-cmo", "laa-cto"]
            }, alreadyPaired: { $0 == "default" }, pair: { name in
                try await Task.sleep(for: .seconds(2))
                if name == "laa-cmo" && !self.failed {
                    self.failed = true
                    throw URLError(.notConnectedToInternet)
                }
            })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Button { available.toggle() } label: {
                        Text(verbatim: available ? "接続済み（テスト）" : "接続する（テスト）")
                    }
                        .accessibilityIdentifier("pair-all.fixture.connection")
                    Text(verbatim: "通知をこのiPhoneに設定します。")
                        .font(.footnote)
                    LAANotificationPairAllControls(model: model, dashboardID: fake.dashboardID,
                        installationID: fake.installationID, canStart: available,
                        source: { fake.source() }, displayName: { $0 })
                }
                .padding()
            }
            .navigationTitle(Text(verbatim: "通知"))
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-LAA_PAIR_ALL_SCREENSHOT") else { return }
            available = true
            await model.run(source: fake.source())
        }
    }
}
#endif
