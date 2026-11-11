#if LAA_BUILD
import SwiftUI

/// What the introduction says about each employee: a one-line motto and
/// what they take on. Taken from each role's own definition in HQ
/// (`hq/roles/<role>/SOUL.md`), shortened; nothing here adds a duty.
extension LAACopy {
    static let staffIntroDuty = "担当"
    static let staffIntroVoice = "通話の声"
    static let staffIntroVoiceNote = "ChatGPT の声を社員ごとに設定します"
    static let staffIntroConversation = "会話"
    static let staffIntroTurnHint = "左右になぞると回ります"
    static let conversationInfo = "会話の情報"
    static let conversationInfoContents = "背景・検索・これまでの会話・モデル"

    static func staffIntroHeaderLabel(_ name: String) -> String { name + "の紹介" }

    static func staffMotto(_ staff: LAAStaff) -> String {
        switch staff {
        case .monet, .monetUncensored, .monetDots: return "社長の相談相手として、計画から実行までを支える"
        case .argus: return "条件とリスクから判断を支える"
        case .cfo: return "差異を説明できる数字を返す"
        case .cio: return "時点と比較条件の揃った市場材料を渡す"
        case .cos: return "次に動く人と条件を明らかにする"
        case .cso: return "再現できる所見と対処を返す"
        case .cto: return "小さく直し、動作と反映を証明する"
        }
    }

    static func staffDuty(_ staff: LAAStaff) -> String {
        switch staff {
        case .monet, .monetUncensored, .monetDots:
            return "予定・タスク、健康・習慣・学習、裁量トレードと事業、発信・デザインを支えます。社員と実作業をまとめる窓口です。"
        case .argus: return "裁量トレードの環境認識・計画案・振り返りと、自動売買の研究の状況を伝えます。"
        case .cfo: return "LAAの会計・資金と、社長個人の取引損益を照合します。"
        case .cio: return "金利・ドル・指標・ニュースなど、チャートの外の材料を届けます。"
        case .cos: return "案件の依存・実績・次の行動を整理し、止まっている仕事を動かします。"
        case .cso: return "許可された対象の脆弱性・設定・秘密の露出・過大な権限を点検します。"
        case .cto: return "開発・インフラの不具合を再現し、最小の変更で直します。"
        }
    }
}

extension AppState {
    /// The employee's ChatGPT voice for calls, or nil for a profile that has
    /// no in-app call.
    func laaEmployeeVoiceBinding(profile: String) -> Binding<String>? {
        guard let staff = LAAStaff(profile: profile), staff.supportsCalls else { return nil }
        return Binding(get: { self.laaEmployeeVoice(profile: profile) ?? staff.defaultGPTLiveVoice },
                       set: { self.setLAAEmployeeVoice($0, profile: profile) })
    }
}

/// The employee's introduction, opened by tapping the mascot in a chat: the
/// mascot large enough to turn with a finger, the name and role, a motto, and
/// rows for what they do, their call voice and the conversation's own
/// information (pushed, so the chat keeps one header control).
struct LAAStaffIntroView: View {
    let profile: String
    let name: String
    var avatarURL: URL? = nil
    var status: String = ""
    var voiceSetting: Binding<String>? = nil
    var voiceSettingEnabled = true
    /// The conversation's information page; nil where there is none (a
    /// chat that has not opened yet).
    var information: AnyView? = nil
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var staff: LAAStaff? { LAAStaff(profile: profile) }
    private var turns: Bool { StaffAssetResolver.bundled.resolve(profile: profile).turn != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    identity.padding(.top, LAASpacing.x3)
                    if let staff {
                        Text(verbatim: LAACopy.staffMotto(staff))
                            .laaTextStyle(.body)
                            .foregroundStyle(LAAColor.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, LAASpacing.x5)
                            .padding(.horizontal, LAASpacing.x6)
                            .accessibilityIdentifier("laa.staff.intro.motto")
                    }
                    rows.padding(.top, LAASpacing.x8)
                }
                .padding(.bottom, LAASpacing.x8)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(LAAColor.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onClose) { Text(verbatim: LAACopy.close) }
                }
            }
        }
        .tint(LAAColor.link)
        .laaSheetSize(.form)
        .presentationDetents([.large])
        .presentationBackground(LAAColor.background)
        .accessibilityIdentifier("laa.staff.intro")
    }

    /// The mascot on a hairline orbit: the arc says it turns, and is the
    /// brand's arc rather than a stage or a shadow.
    private var hero: some View {
        VStack(spacing: LAASpacing.x2) {
            ZStack(alignment: .bottom) {
                Ellipse()
                    .strokeBorder(LAAColor.separator, lineWidth: 1)
                    .frame(width: 196, height: 30)
                    // Through the mascot's own soft shadow, so it stands on
                    // the orbit rather than above a ring.
                    .offset(y: -22)
                    .accessibilityHidden(true)
                StaffMascotView(profile: profile, name: name, fallbackURL: avatarURL, size: 248)
            }
            .frame(height: 256)
            if turns && !reduceMotion {
                Text(verbatim: LAACopy.staffIntroTurnHint)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(LAAColor.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, LAASpacing.x4)
    }

    private var identity: some View {
        VStack(spacing: LAASpacing.x2) {
            Text(verbatim: LAAChatPerson.name(name))
                .font(LAAType.title(LAAChatPerson.name(name), size: 34, relativeTo: .largeTitle))
                .foregroundStyle(LAAColor.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let role = staff?.role {
                Text(verbatim: role)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(LAAColor.link)
                    .multilineTextAlignment(.center)
            }
            if !status.isEmpty {
                Text(verbatim: status)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
            }
        }
        .padding(.horizontal, LAASpacing.horizontal)
    }

    @ViewBuilder private var rows: some View {
        VStack(spacing: 0) {
            if let staff {
                LAAStaffIntroRow(label: LAACopy.staffIntroDuty) {
                    Text(verbatim: LAACopy.staffDuty(staff))
                        .laaTextStyle(.body)
                        .foregroundStyle(LAAColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let voiceSetting {
                LAAStaffIntroRow(label: LAACopy.staffIntroVoice) {
                    VStack(alignment: .leading, spacing: LAASpacing.x1) {
                        Picker(selection: voiceSetting) {
                            ForEach(GPTLiveVoice.all) { voice in Text(voice.label).tag(voice.name) }
                        } label: {
                            Text(verbatim: LAACopy.staffIntroVoice)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .padding(.leading, -12)
                        .disabled(!voiceSettingEnabled)
                        .accessibilityIdentifier("laa.employee.voice-setting")
                        Text(verbatim: LAACopy.staffIntroVoiceNote)
                            .laaTextStyle(.secondary)
                            .foregroundStyle(LAAColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let information {
                NavigationLink {
                    information
                        .environment(\.laaDismissConversationInfo, onClose)
                        .navigationTitle(Text(verbatim: LAACopy.conversationInfo))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(action: onClose) { Text(verbatim: LAACopy.done) }
                            }
                        }
                } label: {
                    LAAStaffIntroRow(label: LAACopy.staffIntroConversation) {
                        HStack(spacing: LAASpacing.x2) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: LAACopy.conversationInfo)
                                    .laaTextStyle(.body)
                                    .foregroundStyle(LAAColor.text)
                                Text(verbatim: LAACopy.conversationInfoContents)
                                    .laaTextStyle(.secondary)
                                    .foregroundStyle(LAAColor.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LAAColor.secondaryText)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: LAACopy.conversationInfo))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("laa.staff.intro.conversation")
            }
            Rectangle().fill(LAAColor.separator).frame(height: 0.5).accessibilityHidden(true)
        }
        .padding(.horizontal, LAASpacing.horizontal)
    }
}

/// One row of the introduction: a small spaced label on the left and the
/// content on the right, ruled above rather than boxed. At accessibility
/// text sizes the label goes above the content.
private struct LAAStaffIntroRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LAASpacing.x2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LAASpacing.x4))
        layout {
            Text(verbatim: label)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(LAAColor.secondaryText)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 64, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, LAASpacing.x4)
        .overlay(alignment: .top) {
            Rectangle().fill(LAAColor.separator).frame(height: 0.5).accessibilityHidden(true)
        }
    }
}
#endif
