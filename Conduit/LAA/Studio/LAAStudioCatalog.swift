#if LAA_BUILD
import SwiftUI

struct LAAStudioCatalogView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let snapshot: LAAStudioSnapshot
    @State private var catalog: LAAStudioCatalog?
    @State private var stale = false
    @State private var loading = false
    @State private var loadID: UUID?
    @State private var error: String?
    @State private var category = "すべて"
    private var categories: [String] { ["すべて"] + Array(Set(catalog?.documents.map(\.category) ?? [])).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            if let error {
                Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                Button { Task { await load() } } label: { Text(verbatim: LAACopy.Studio.retry).frame(minHeight: LAASpacing.minimumTouchTarget) }
            }
            if loading && catalog == nil { LAAStudioSkeleton() }
            if let catalog {
                if stale { Text(verbatim: "接続できないため、この端末に保存した内容を表示しています。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                Text(verbatim: "更新 \(LAAStudioPresentation.relativeDate(catalog.updatedAt))").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                HStack {
                    Text(verbatim: "原則 · \(catalog.principles.count)").laaTextStyle(.section).fontWeight(.semibold)
                    Spacer()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget) }
                        .disabled(loading).accessibilityLabel(Text(verbatim: LAACopy.Studio.refresh))
                }
                ForEach(catalog.principles) { principle in
                    NavigationLink { LAAStudioPrincipleView(principle: principle, snapshot: snapshot) } label: {
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: principle.name).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                            Text(verbatim: "\(principle.status == "adopted" ? "採用済み" : "下書き") · v\(principle.version)")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }.padding(LAASpacing.x3).frame(maxWidth: .infinity, alignment: .leading)
                            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    }.buttonStyle(.plain)
                }
                Text(verbatim: "正式資料 · \(catalog.documents.count)").laaTextStyle(.section).fontWeight(.semibold)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LAASpacing.x2) {
                        ForEach(categories, id: \.self) { item in
                            Button { category = item } label: {
                                Text(verbatim: item).studioFilterChip(selected: category == item)
                            }.buttonStyle(.plain).accessibilityAddTraits(category == item ? .isSelected : [])
                        }
                    }
                }.scrollClipDisabled()
                ForEach(catalog.documents.filter { category == "すべて" || $0.category == category }) { document in
                    NavigationLink { LAAStudioDocumentView(document: document) } label: {
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: document.title).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
                            Text(verbatim: "\(document.category) · \(document.format) · \(document.detail)")
                                .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }.padding(LAASpacing.x3).frame(maxWidth: .infinity, alignment: .leading)
                            .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
                    }.buttonStyle(.plain)
                }
            }
        }.task(id: bridge.revision) {
            catalog = nil; stale = false
            await load()
        }
    }
    @MainActor private func load() async {
        let id = UUID(); loadID = id
        loading = true; error = nil
        defer { if loadID == id { loading = false } }
        do {
            let result = try await LAAStudioData.catalog(bridge)
            guard loadID == id else { return }
            catalog = result.catalog; stale = result.stale
        }
        catch is CancellationError { }
        catch {
            guard loadID == id else { return }
            if LAAStudioData.isAuthorizationFailure(error) { catalog = nil; stale = false }
            self.error = LAAStudioData.message(error)
        }
    }
}

private struct LAAStudioPrincipleView: View {
    let principle: LAAStudioCatalog.Principle
    let snapshot: LAAStudioSnapshot
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: principle.name).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(principle.status == "adopted" ? "採用済み" : "下書き") · v\(principle.version) · 第\(principle.revision)版")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Text(verbatim: principle.description).laaTextStyle(.body)
                NavigationLink {
                    LAAStudioCreateView(snapshot: snapshot, draftID: LAAStudioDraftStore.principleDraftID(principle.id),
                                        initialPrinciple: principle.requestPrinciple)
                } label: {
                    Text(verbatim: "この原則で始める")
                }.laaGlassButton(prominent: true)
                heading("色")
                ForEach(Array(principle.colors.enumerated()), id: \.offset) { _, color in
                    HStack(alignment: .top, spacing: LAASpacing.x3) {
                        colorSwatch(color.value).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: "\(color.name) · \(color.value)").laaTextStyle(.body).fontWeight(.semibold)
                            if let rgb = color.rgb { detail("RGB", rgb.text) }
                            if let oklch = color.oklch { detail("OKLCH", oklch.text) }
                            if let cmyk = color.cmykApprox { detail("CMYK（目安）", cmyk.text) }
                        }
                    }
                }
                heading("書体")
                ForEach(Array(principle.fonts.enumerated()), id: \.offset) { _, font in
                    Text(verbatim: "\(font.name) · \(font.family) · \(font.weight.formatted()) / \(font.size.formatted())")
                        .laaTextStyle(.body)
                }
                heading("参考画像")
                ForEach(Array(principle.references.enumerated()), id: \.offset) { _, reference in
                    VStack(alignment: .leading, spacing: LAASpacing.x2) {
                        LAAStudioThumbnail(path: reference.media, symbol: "photo").aspectRatio(1.6, contentMode: .fit)
                        Text(verbatim: "\(reference.name) · \(reference.role == "primary" ? "主参考" : "補助")").laaTextStyle(.body).fontWeight(.semibold)
                        Text(verbatim: reference.adoptedElements).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                    }
                }
                heading("型")
                ForEach(Array(principle.templates.enumerated()), id: \.offset) { _, template in Text(verbatim: template).laaTextStyle(.body) }
                if let priorities = principle.priorities, !priorities.isEmpty {
                    heading("優先事項")
                    ForEach(Array(priorities.enumerated()), id: \.offset) { _, priority in
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: priority.title).laaTextStyle(.body).fontWeight(.semibold)
                            Text(verbatim: priority.description).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: "原則"))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
    }
    private func heading(_ title: String) -> some View { Text(verbatim: title).laaTextStyle(.section).fontWeight(.semibold) }
    private func detail(_ title: String, _ value: String) -> some View {
        Text(verbatim: "\(title): \(value)").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
    }
    private func colorSwatch(_ value: String) -> Color {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return LAAColor.subtleSurface }
        let rgb = hex.count == 8 ? number >> 8 : number
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

private struct LAAStudioDocumentView: View {
    let document: LAAStudioCatalog.Document
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LAASpacing.x4) {
                Text(verbatim: document.title).font(LAAType.screenTitle).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(document.category) · \(document.detail)").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if let url = LAAStudioMedia.driveURL(document.driveUrl) {
                    Link(destination: url) { Label { Text(verbatim: "Driveで開く") } icon: { Image(systemName: "arrow.up.right.square") }.frame(minHeight: LAASpacing.minimumTouchTarget) }
                        .accessibilityIdentifier("laa.studio.document.drive")
                }
                if LAAStudioMedia.bridgePath(document.media, allowed: ["pdf"]) != nil { LAAStudioFilePreview(path: document.media, driveURL: document.driveUrl) }
                else { Text(verbatim: "アプリ用の資料を読み込めません。Driveで開いてください。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: "正式資料"))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
    }
}
#endif
