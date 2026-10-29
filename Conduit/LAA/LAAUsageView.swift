#if LAA_BUILD
import SwiftUI

struct LAAUsageView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let onRequestSettings: () -> Void
    @State private var usage: [LAAUsageItem] = []
    @State private var mac: [LAAUsageItem] = []
    @State private var usageError: LAABridgeError?
    @State private var macError: LAABridgeError?
    @State private var updatedAt: Date?
    @State private var isLoading = false
    @State private var generation = 0
    @State private var showPairing = false

    var body: some View {
        ZStack {
            LAAColors.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: LAASpacing.x6) {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Text(verbatim: "Usage")
                            .font(LAAFont.largeHeading)
                            .foregroundStyle(LAAColors.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: "更新時刻 " + time(updatedAt))
                            .font(LAAFont.caption)
                            .foregroundStyle(LAAColors.muted)
                    }
                    if bridge.status != .paired {
                        connectionCard
                    } else {
                        if isLoading && usage.isEmpty && mac.isEmpty {
                            ProgressView().accessibilityLabel(Text(verbatim: LAACopy.loading))
                        }
                        section("利用枠", items: usage.filter { $0.kind == "quota" }, error: usageError)
                        section("残高", items: usage.filter { $0.kind == "balance" }, error: usageError)
                        let other = usage.filter { $0.kind != "quota" && $0.kind != "balance" }
                        if !other.isEmpty { section("その他", items: other, error: nil) }
                        section("Macの状態", items: mac, error: macError)
                    }
                }
                .padding(.horizontal, LAASpacing.x4)
                .padding(.top, LAASpacing.x2)
                .padding(.bottom, LAASpacing.x8)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await refresh() }
        }
        .navigationTitle(Text(verbatim: "Usage"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if bridge.status == .paired {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPairing = true } label: { Image(systemName: "network") }
                        .accessibilityLabel(Text(verbatim: "Macとの接続"))
                        .accessibilityIdentifier("laa.bridge.manage")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRequestSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text(verbatim: LAACopy.settings))
            }
        }
        .tint(LAAColors.teal)
        .sheet(isPresented: $showPairing) { LAAPairingView().environmentObject(bridge) }
        .task(id: bridge.revision) {
            if bridge.status == .paired { await refresh() }
            else {
                generation += 1
                usage = []; mac = []; usageError = nil; macError = nil; updatedAt = nil
                isLoading = false
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Label { Text(verbatim: LAACopy.notConnected) } icon: { Image(systemName: "circle") }
                .foregroundStyle(LAAColors.muted)
            Text(verbatim: bridge.status == .revoked || bridge.status == .unauthorized
                 ? "この端末の接続が無効になりました。新しいコードで接続してください。"
                 : bridge.status == .keychainError
                    ? LAABridgeError.keychain.japaneseText : LAACopy.bridgeNotPairedBody)
                .foregroundStyle(LAAColors.ink)
            if bridge.status != .keychainError {
                Button { showPairing = true } label: { Text(verbatim: "Macに接続する") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("laa.bridge.openPairing")
            }
        }
        .padding(LAASpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColors.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func section(_ title: String, items: [LAAUsageItem], error: LAABridgeError?) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x3) {
            Text(verbatim: title).font(.headline).foregroundStyle(LAAColors.ink)
                .accessibilityAddTraits(.isHeader)
            if let error {
                Label { Text(verbatim: error.japaneseText) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(LAAFont.caption).foregroundStyle(LAAColors.plum)
            } else if items.isEmpty && !isLoading {
                Label { Text(verbatim: LAACopy.notFetched) } icon: { Image(systemName: "circle") }
                    .foregroundStyle(LAAColors.muted)
            }
            if !items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        itemRow(item)
                        if index < items.count - 1 { LAAColors.hairline.frame(height: 1) }
                    }
                }
                .padding(.horizontal, LAASpacing.x4)
                .background(LAAColors.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LAAColors.hairline))
            }
        }
    }

    private func itemRow(_ item: LAAUsageItem) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                Text(verbatim: item.label).font(.body.weight(.medium)).foregroundStyle(LAAColors.ink)
                Spacer(minLength: LAASpacing.x2)
                if item.kind != "quota" || item.detail?.windows?.isEmpty != false {
                    Text(verbatim: value(item.availableValue, unit: item.unit))
                        .font(.custom("Iowan Old Style", size: 20, relativeTo: .body))
                        .monospacedDigit().foregroundStyle(LAAColors.ink)
                }
            }
            if item.kind == "quota", let windows = item.detail?.windows, !windows.isEmpty {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: window.label).foregroundStyle(LAAColors.muted)
                        Spacer(minLength: LAASpacing.x2)
                        let remaining = item.availability == "available" ? window.remainingPercent : nil
                        Text(verbatim: remaining.map { "残り " + value($0, unit: "percent") } ?? LAACopy.notFetched)
                            .font(.custom("Iowan Old Style", size: 19, relativeTo: .body))
                            .monospacedDigit().foregroundStyle(LAAColors.ink)
                    }
                    if let reset = LAAUsageItem.date(window.resetsAt) {
                        Text(verbatim: (reset < Date() ? "更新期限切れ " : "更新予定 ") + time(reset))
                            .font(LAAFont.caption)
                            .foregroundStyle(reset < Date() ? LAAColors.plum : LAAColors.muted)
                    } else {
                        Text(verbatim: "更新予定 未取得").font(LAAFont.caption).foregroundStyle(LAAColors.muted)
                    }
                }
            }
            if item.kind == "host.memory", let total = item.detail?.totalBytes, item.availableValue != nil {
                Text(verbatim: "合計 " + value(total, unit: "bytes"))
                    .font(LAAFont.caption).foregroundStyle(LAAColors.muted)
            }
            if item.kind == "host.disk", let total = item.detail?.totalGb, item.availableValue != nil {
                Text(verbatim: "合計 " + value(total, unit: "gb"))
                    .font(LAAFont.caption).foregroundStyle(LAAColors.muted)
            }
            if item.availableValue == nil {
                Label { Text(verbatim: nullReason(item.nullReason)) } icon: { Image(systemName: "circle") }
                    .font(LAAFont.caption).foregroundStyle(LAAColors.muted)
            }
            let flags = [item.stale ? "古い値" : nil, item.isExpired() ? "期限切れ" : nil,
                         item.estimated ? "推計" : nil].compactMap { $0 }
            if !flags.isEmpty {
                Label { Text(verbatim: flags.joined(separator: "・")) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(LAAFont.caption).foregroundStyle(LAAColors.plum)
            }
            if let expires = item.detail?.expiresOnUtc {
                Text(verbatim: "有効期限 " + expires).font(LAAFont.caption).foregroundStyle(LAAColors.muted)
            }
            if let renews = LAAUsageItem.date(item.detail?.renewsAt) {
                Text(verbatim: "更新予定 " + time(renews)).font(LAAFont.caption).foregroundStyle(LAAColors.muted)
            }
            Text(verbatim: "確認時刻 " + time(LAAUsageItem.date(item.observedAt)))
                .font(LAAFont.caption).foregroundStyle(LAAColors.muted)
        }
        .padding(.vertical, LAASpacing.x3)
    }

    private func nullReason(_ reason: String?) -> String {
        switch reason {
        case "not_configured": return "未取得・未設定"
        case "fetch_failed": return "未取得・取得に失敗"
        case "unsupported": return "未取得・未対応"
        case "auth_required": return "未取得・認証が必要"
        default: return LAACopy.notFetched
        }
    }

    private func value(_ number: Double?, unit: String) -> String {
        guard let number, number.isFinite else { return LAACopy.notFetched }
        if unit == "bytes" {
            guard number >= 0, number < Double(Int64.max) else { return LAACopy.notFetched }
            return ByteCountFormatter.string(fromByteCount: Int64(number), countStyle: .memory)
        }
        let digits = number.formatted(.number.precision(.fractionLength(0...2)))
        switch unit {
        case "percent": return digits + "%"
        case "usd": return "$" + digits
        case "jpy": return "¥" + digits
        case "gb": return digits + " GB"
        case "credits": return digits + " credits"
        case "tokens": return digits + " tokens"
        case "count": return digits
        default: return digits + " " + unit
        }
    }

    private func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refresh() async {
        guard bridge.status == .paired else { return }
        generation += 1
        let mine = generation
        isLoading = true
        async let usageResult = loadPages("/v1/usage")
        async let macResult = loadPages("/v1/mac/status")
        let (newUsage, newMac) = await (usageResult, macResult)
        guard mine == generation, !Task.isCancelled, bridge.status == .paired else { return }
        isLoading = false
        switch newUsage {
        case .success(let items): usage = items; usageError = nil
        case .failure(let error): usage = []; usageError = error
        }
        switch newMac {
        case .success(let items): mac = items; macError = nil
        case .failure(let error): mac = []; macError = error
        }
        updatedAt = usageError == nil || macError == nil ? Date() : nil
    }

    private func loadPages(_ path: String) async -> Result<[LAAUsageItem], LAABridgeError> {
        var items: [LAAUsageItem] = []
        var cursor: String?
        var seen = Set<String>()
        do {
            repeat {
                var route = path
                if let cursor {
                    var parts = URLComponents()
                    parts.path = path
                    parts.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
                    guard let encoded = parts.string else { throw LAABridgeError.invalidResponse }
                    route = encoded
                }
                let page: LAAUsagePage = try await bridge.read(route)
                items.append(contentsOf: page.items)
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted || seen.count > 100 {
                    throw LAABridgeError.invalidResponse
                }
            } while cursor != nil
            return .success(items)
        } catch let error as LAABridgeError { return .failure(error) }
        catch { return .failure(.networkUnreachable) }
    }
}
#endif
