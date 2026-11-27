#if LAA_BUILD
import SwiftUI

struct LAAStudioCatalogView: View {
    @EnvironmentObject private var bridge: LAABridgeSession
    let snapshot: LAAStudioSnapshot
    var showsPrinciples = true
    @State private var catalog: LAAStudioCatalog?
    @State private var stale = false
    @State private var loading = false
    @State private var loadID: UUID?
    @State private var error: String?
    @State private var category: String?
    private var categories: [String] { Array(Set(catalog?.documents.map(\.category) ?? [])).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: LAASpacing.x4) {
            if let error {
                Text(verbatim: error).laaTextStyle(.secondary).foregroundStyle(LAAColor.attention)
                Button { Task { await load() } } label: { Text(verbatim: LAACopy.Studio.retry).frame(minHeight: LAASpacing.minimumTouchTarget) }
            }
            if loading && catalog == nil { LAALoadingDots() }
            if let catalog {
                if stale { Text(verbatim: "接続できないため、この端末に保存した内容を表示しています。")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.attention) }
                if showsPrinciples { principleRows(catalog) }
                else { documentRows(catalog) }
            }
        }.task(id: bridge.revision) {
            catalog = nil; stale = false
            await load()
        }
    }

    @ViewBuilder private func principleRows(_ catalog: LAAStudioCatalog) -> some View {
        HStack {
            LAASectionHeader("Design Principles")
            Spacer()
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: LAASpacing.minimumTouchTarget, minHeight: LAASpacing.minimumTouchTarget)
            }
            .disabled(loading).accessibilityLabel(Text(verbatim: LAACopy.Studio.refresh))
        }
        ForEach(catalog.principles) { principle in
            NavigationLink { LAAStudioPrincipleView(principle: principle, snapshot: snapshot) } label: {
                catalogRow(principle.name, detail: "\(principle.status == "adopted" ? "Adopted" : "Draft") · v\(principle.version)")
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func documentRows(_ catalog: LAAStudioCatalog) -> some View {
        LAASectionHeader("Documents")
        Picker("Category", selection: $category) {
            Text("All").tag(nil as String?)
            ForEach(categories, id: \.self) { item in Text(verbatim: item).tag(Optional(item)) }
        }
        ForEach(catalog.documents.filter { category == nil || $0.category == category }) { document in
            NavigationLink { LAAStudioDocumentView(document: document) } label: {
                catalogRow(document.title, detail: "\(document.category) · \(document.format) · \(document.detail)")
            }.buttonStyle(.plain)
        }
    }

    private func catalogRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: LAASpacing.x1) {
            Text(verbatim: title).laaTextStyle(.body).fontWeight(.semibold).foregroundStyle(LAAColor.text)
            Text(verbatim: detail).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
        }
        .padding(LAASpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LAAColor.surface, in: RoundedRectangle(cornerRadius: LAARadius.card))
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
                Text(verbatim: principle.name).font(LAAType.title(principle.name)).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(principle.status == "adopted" ? "採用済み" : "下書き") · v\(principle.version) · 第\(principle.revision)版")
                    .laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                Text(verbatim: principle.description).laaTextStyle(.body)
                NavigationLink {
                    LAAStudioCreateView(snapshot: snapshot, draftID: LAAStudioDraftStore.principleDraftID(principle.id),
                                        initialPrinciple: principle.requestPrinciple)
                } label: {
                    Text(verbatim: "この原則で始める")
                }.laaGlassButton(prominent: true)
                heading("Color")
                ForEach(Array(principle.colors.enumerated()), id: \.offset) { _, color in
                    HStack(alignment: .top, spacing: LAASpacing.x3) {
                        colorSwatch(color.value).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: "\(color.name) · \(color.value)").laaTextStyle(.body).fontWeight(.semibold)
                            if let rgb = color.rgb { detail("RGB", rgb.text) }
                            if let oklch = color.oklch { detail("OKLCH", oklch.text) }
                            if let cmyk = color.cmykApprox { detail("CMYK (Approx.)", cmyk.text) }
                        }
                    }
                }
                heading("Typeface")
                ForEach(Array(principle.fonts.enumerated()), id: \.offset) { _, font in
                    Text(verbatim: "\(font.name) · \(font.family) · \(font.weight.formatted()) / \(font.size.formatted())")
                        .laaTextStyle(.body)
                }
                heading("Reference Image")
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
                    heading("Priorities")
                    ForEach(Array(priorities.enumerated()), id: \.offset) { _, priority in
                        VStack(alignment: .leading, spacing: LAASpacing.x1) {
                            Text(verbatim: priority.title).laaTextStyle(.body).fontWeight(.semibold)
                            Text(verbatim: priority.description).laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                        }
                    }
                }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: "Principles"))
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
                Text(verbatim: document.title).font(LAAType.title(document.title)).foregroundStyle(LAAColor.text)
                Text(verbatim: "\(document.category) · \(document.detail)").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText)
                if let url = LAAStudioMedia.driveURL(document.driveUrl) {
                    Link(destination: url) { Label { Text(verbatim: "Open in Drive") } icon: { Image(systemName: "arrow.up.right.square") }.frame(minHeight: LAASpacing.minimumTouchTarget) }
                        .accessibilityIdentifier("laa.studio.document.drive")
                }
                if LAAStudioMedia.bridgePath(document.media, allowed: ["pdf"]) != nil { LAAStudioFilePreview(path: document.media, driveURL: document.driveUrl) }
                else { Text(verbatim: "アプリ用の資料を読み込めません。Driveで開いてください。").laaTextStyle(.secondary).foregroundStyle(LAAColor.secondaryText) }
            }.padding(LAASpacing.horizontal).laaPageWidth()
        }.background(LAAColor.background.ignoresSafeArea()).navigationTitle(Text(verbatim: "Official Documents"))
            .navigationBarTitleDisplayMode(.inline).tint(LAAColor.link)
    }
}
#endif
