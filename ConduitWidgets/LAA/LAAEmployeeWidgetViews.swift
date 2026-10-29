#if LAA_BUILD
import AppIntents
import SwiftUI
import WidgetKit

extension LAAWidgetEmployee: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "社員")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .ciel: "Ciel", .argus: "Argus", .cfo: "Morgan", .cio: "Sherlock",
        .cmo: "Monet", .cos: "Merlin", .cto: "Ada", .cso: "Talos"
    ]
}

struct LAAEmployeeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "社員"
    static let description = IntentDescription("ホーム画面から社員の会話や電話を開きます。")
    @Parameter(title: "社員", default: .ciel) var employee: LAAWidgetEmployee
    init() { employee = .defaultEmployee }
}

struct LAAEmployeeWidgetEntry: TimelineEntry {
    let date: Date
    let employee: LAAWidgetEmployee
    let chat: WidgetLaunchLink
    let call: WidgetLaunchLink

    static func make(employee: LAAWidgetEmployee, snapshot: WidgetSnapshot?) -> Self {
        Self(date: Date(), employee: employee,
             chat: LAAEmployeeWidgetLinks.link(employee: employee, action: .employeeChat, snapshot: snapshot),
             call: LAAEmployeeWidgetLinks.link(employee: employee, action: .talk, snapshot: snapshot))
    }
}

struct LAAEmployeeTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LAAEmployeeWidgetEntry { .make(employee: .defaultEmployee, snapshot: nil) }
    func snapshot(for configuration: LAAEmployeeWidgetIntent, in context: Context) async -> LAAEmployeeWidgetEntry {
        .make(employee: configuration.employee, snapshot: WidgetSnapshotStore.production?.read())
    }
    func timeline(for configuration: LAAEmployeeWidgetIntent, in context: Context) async -> Timeline<LAAEmployeeWidgetEntry> {
        let entry = LAAEmployeeWidgetEntry.make(employee: configuration.employee, snapshot: WidgetSnapshotStore.production?.read())
        return Timeline(entries: [entry], policy: .never)
    }
}

struct LAAEmployeeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: ConduitWidgetKind.employee, intent: LAAEmployeeWidgetIntent.self, provider: LAAEmployeeTimelineProvider()) { entry in
            LAAEmployeeWidgetView(entry: entry)
        }
        .configurationDisplayName("LAA 社員")
        .description("社員を選び、会話や電話を開きます。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct LAAEmployeeWidgetView: View {
    let entry: LAAEmployeeWidgetEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch familyOverride ?? family {
            case .systemSmall: small
            case .accessoryCircular: circular
            default: medium
            }
        }
        .containerBackground(for: .widget) { background }
    }

    private var background: Color {
        colorScheme == .dark ? Color(red: 15/255, green: 27/255, blue: 28/255)
            : Color(red: 246/255, green: 242/255, blue: 233/255)
    }

    private var small: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.employee.name)
                        .font(.custom("Georgia", size: 19))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 13)
                        .padding(.horizontal, 14)
                    Spacer(minLength: 0)
                }
                employeeImage(entry.employee.heroImage)
                    .scaledToFit()
                    .frame(width: geometry.size.width * 0.9, height: geometry.size.height * 0.83)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .accessibilityHidden(true)
                Link(destination: entry.call.url) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color(red: 0.08, green: 0.40, blue: 0.38), in: Circle())
                }
                .accessibilityLabel("\(entry.employee.name) に電話")
                .padding(11)
            }
        }
        .widgetURL(entry.chat.url)
        .accessibilityLabel("\(entry.employee.name) の会話")
    }

    private var medium: some View {
        HStack(spacing: 12) {
            employeeImage(entry.employee.avatarImage)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.employee.name)
                    .font(.custom("Georgia", size: 22))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(entry.employee.role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    action(entry.call.url, title: "電話", symbol: "phone.fill")
                    action(entry.chat.url, title: "チャット", symbol: "bubble.left.fill")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 17)
        }
        .padding(.horizontal, 14)
        .widgetURL(entry.chat.url)
    }

    private var circular: some View {
        Image("LAAWidgetMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .padding(8)
            .widgetURL(entry.call.url)
            .accessibilityLabel("\(entry.employee.name) に電話")
    }

    @ViewBuilder
    private func employeeImage(_ name: String) -> some View {
        if #available(iOS 18.0, *) {
            Image(name).resizable().widgetAccentedRenderingMode(.accentedDesaturated).widgetAccentable()
                .saturation(renderingMode == .accented ? 0 : 1)
        } else {
            Image(name).resizable()
        }
    }

    private func action(_ url: URL, title: String, symbol: String) -> some View {
        Link(destination: url) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(.quaternary, in: Capsule())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("\(entry.employee.name) に\(title)")
    }
}
#endif
