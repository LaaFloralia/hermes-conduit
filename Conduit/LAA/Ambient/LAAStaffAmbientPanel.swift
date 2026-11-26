#if LAA_BUILD && targetEnvironment(macCatalyst)
import SwiftUI

/// What the chat column tells the Mac's staff panel: the open employee chat's
/// profile, the model Hermes reports for it and its last message time. Read
/// once by the chat section, so the panel redraws only when these change and
/// not on every streamed token.
struct LAAStaffAmbientInputs: Equatable {
    var profile: String?
    var model: String?
    var lastActivity: Date?

    @MainActor init(_ appState: AppState) {
        profile = appState.activeRoomSurface == nil ? appState.conversationIdentityProfile : nil
        model = appState.laaChatRuntime.shown(for: Set([appState.activeSessionId].compactMap { $0 })).model
        lastActivity = appState.messages
            .last { ($0.role == .assistant || $0.role == .user) && !$0.content.isEmpty }
            .flatMap { MessageTimestampFormatter.date(from: $0.timestamp) }
    }

    init(profile: String?, model: String?, lastActivity: Date?) {
        self.profile = profile; self.model = model; self.lastActivity = lastActivity
    }
}

extension View {
    /// The Mac's staff panel on the right of an employee chat (HO-26),
    /// collapsible; nothing beside a group room or a non-employee profile.
    func laaStaffAmbientPanel(_ inputs: LAAStaffAmbientInputs) -> some View {
        modifier(LAAStaffAmbientPanelModifier(inputs: inputs))
    }
}

private struct LAAStaffAmbientPanelModifier: ViewModifier {
    let inputs: LAAStaffAmbientInputs
    @AppStorage("laa.mac.staffPanel.open") private var open = true

    private var effective: LAAStaffAmbientInputs {
        #if DEBUG
        if LAAStaffAmbientFixture.enabled { return LAAStaffAmbientFixture.inputs }
        #endif
        return inputs
    }

    func body(content: Content) -> some View {
        let inputs = effective
        if let profile = inputs.profile, LAAStaff(profile: profile) != nil {
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(LAAColor.separator).frame(width: 1).ignoresSafeArea()
                if open {
                    LAAStaffAmbientPanel(inputs: inputs, profile: profile) { open = false }
                        .frame(width: LAAStaffAmbientPanel.width)
                        .transition(.move(edge: .trailing))
                } else {
                    LAAStaffAmbientCollapsed { open = true }
                }
            }
            .animation(.easeOut(duration: 0.22), value: open)
        } else {
            content
        }
    }
}

/// The collapsed panel: one control at the top of a hairline-wide strip.
private struct LAAStaffAmbientCollapsed: View {
    let expand: () -> Void

    var body: some View {
        VStack {
            Button(action: expand) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 16))
                    .foregroundStyle(LAAColor.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "社員の情報を表示"))
            .accessibilityIdentifier("laa.mac.staffPanel.expand")
            Spacer()
        }
        .padding(.top, LAASpacing.x3)
        .frame(width: 44)
        .background(LAAColor.background)
    }
}

struct LAAStaffAmbientPanel: View {
    static let width: CGFloat = 288

    let inputs: LAAStaffAmbientInputs
    let profile: String
    let collapse: () -> Void

    @EnvironmentObject private var bridge: LAABridgeSession
    @State private var rows: [LAAStaffRoutineRow]?
    @State private var failed = false

    private var model: LAAStaffAmbientPanelModel? {
        LAAStaffAmbientPanelModel.make(profile: profile, routines: rows, failed: failed,
                                       model: inputs.model, lastActivity: inputs.lastActivity)
    }

    var body: some View {
        ScrollView {
            if let model { content(model) }
        }
        .scrollIndicators(.never)
        .background(LAAColor.background)
        .accessibilityIdentifier("laa.mac.staffPanel")
        .task(id: "\(profile)|\(bridge.revision)") { await load() }
    }

    private func content(_ model: LAAStaffAmbientPanelModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button(action: collapse) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 16))
                        .foregroundStyle(LAAColor.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "社員の情報を隠す"))
                .accessibilityIdentifier("laa.mac.staffPanel.collapse")
            }
            StaffMascotView(profile: model.profile, name: model.name, size: 176)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, LAASpacing.x2)
            Text(verbatim: model.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LAAColor.text)
                .padding(.top, LAASpacing.x4)
            Text(verbatim: model.role)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LAAColor.secondaryText)
                .padding(.top, LAASpacing.x1)
            VStack(alignment: .leading, spacing: 0) {
                infoRow("モデル", model.model)
                infoRow("最後の活動", model.lastActivity)
            }
            .padding(.top, LAASpacing.x6)
            // The Work tab's name for them, in the app's section header.
            LAASectionHeader("Routines")
                .padding(.top, LAASpacing.x8)
                .padding(.bottom, LAASpacing.x2)
            routines(model.routines)
        }
        .padding(.horizontal, LAASpacing.x6)
        .padding(.bottom, LAASpacing.x8)
    }

    /// A ruled row: the label on the left, the value on the right; a value
    /// the app does not know shows as an open mark, not as words.
    private func infoRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(.system(size: 13))
                .foregroundStyle(LAAColor.secondaryText)
            Spacer(minLength: LAASpacing.x3)
            Text(verbatim: value ?? LAAStaffAmbientPanelModel.Mark.unknown.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(value == nil ? LAAColor.secondaryText : LAAColor.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func routines(_ state: LAAStaffAmbientPanelModel.Routines) -> some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small).frame(minHeight: 32)
        case .unavailable:
            routineMarkOnly
        case .loaded(let list) where list.isEmpty:
            routineMarkOnly
        case .loaded(let list):
            ForEach(list) { routine in
                HStack(alignment: .firstTextBaseline, spacing: LAASpacing.x2) {
                    Text(verbatim: routine.mark.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(routine.mark == .attention ? LAAColor.attention : LAAColor.link)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: routine.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LAAColor.text)
                            .lineLimit(2)
                        if !routine.detail.isEmpty {
                            Text(verbatim: routine.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(LAAColor.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, LAASpacing.x2)
                .frame(minHeight: 48, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// No routines, or none could be read: the open mark on its ruled row.
    private var routineMarkOnly: some View {
        Text(verbatim: LAAStaffAmbientPanelModel.Mark.unknown.rawValue)
            .font(.system(size: 12))
            .foregroundStyle(LAAColor.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(LAAColor.separator).frame(height: 1) }
            .accessibilityLabel(Text(verbatim: "Routines"))
    }

    private func load() async {
        #if DEBUG
        if LAAStaffAmbientFixture.enabled { rows = LAAStaffAmbientFixture.routines; failed = false; return }
        #endif
        guard bridge.status == .paired else { rows = nil; failed = true; return }
        do {
            let page: LAAWorkPage<LAAStaffRoutineRow> = try await bridge.read("/v1/routines")
            guard !Task.isCancelled else { return }
            rows = page.items
            failed = false
        } catch is CancellationError {
        } catch {
            rows = nil
            failed = true
        }
    }
}

#if DEBUG
/// `-LAA_STAFF_PANEL_FIXTURE`: the panel for Sherlock with fixed routines and
/// model, beside the Mac chat fixture, so it can be photographed without a
/// Bridge or Hermes.
enum LAAStaffAmbientFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-LAA_STAFF_PANEL_FIXTURE") }

    static var inputs: LAAStaffAmbientInputs {
        LAAStaffAmbientInputs(profile: "laa-cio", model: "gpt-6.1-sol", lastActivity: Date().addingTimeInterval(-18 * 60))
    }

    static var routines: [LAAStaffRoutineRow] {
        let iso = ISO8601DateFormatter()
        let now = Date()
        return [
            LAAStaffRoutineRow(id: "r1", name: "朝の市況メモ", schedule: "毎日 7:30",
                               nextRunAt: iso.string(from: now.addingTimeInterval(3 * 3600)), state: "scheduled",
                               destination: "Sherlockのチャット"),
            LAAStaffRoutineRow(id: "r2", name: "週次の情報整理", schedule: "毎週 月 9:00",
                               nextRunAt: iso.string(from: now.addingTimeInterval(2 * 86400)), state: "scheduled",
                               destination: "Sherlockのチャット"),
            LAAStaffRoutineRow(id: "r3", name: "決算カレンダーの確認", schedule: "毎日 18:00", state: "error",
                               destination: "Sherlockのチャット"),
            LAAStaffRoutineRow(id: "r4", name: "Monetの朝の報告", schedule: "毎日 8:00", state: "scheduled",
                               destination: "Monetのチャット"),
        ]
    }
}
#endif
#endif
