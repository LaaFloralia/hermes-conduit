#if LAA_BUILD
import SwiftUI

/// Shared layout contract for the Mac window. The shell sets `laaDesktop`;
/// section views branch on it, never on the size class, because the Mac
/// shell keeps reused iPhone views in a compact size class inside columns.
private struct LAADesktopKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var laaDesktop: Bool {
        get { self[LAADesktopKey.self] }
        set { self[LAADesktopKey.self] = newValue }
    }
}

/// Widths in UIKit points; Catalyst's iPad scaling shows them at about 77%.
enum LAADesktopMetrics {
    static let listMinWidth: CGFloat = 340
    static let listIdealWidth: CGFloat = 390
    /// The share of a section's width its list takes on a narrow window.
    static let listShare: CGFloat = 0.3
    /// A Work session's transcript.
    static let readingWidth: CGFloat = 936
    /// Notes, documents and task details.
    static let documentWidth: CGFloat = 832
    /// Card grids such as Studio works and Usage providers.
    static let gridItemMinWidth: CGFloat = 300

    /// The list column for `available` points: its own `width` once the
    /// window has room, a smaller share of a narrow one (never under the
    /// minimum), so the detail beside it keeps a readable width.
    static func listWidth(_ width: CGFloat, available: CGFloat) -> CGFloat {
        min(width, max(listMinWidth, (available * listShare).rounded(.down)))
    }
}

/// A list column beside its detail, separated by a hairline. The list keeps
/// its width as the window grows; the detail takes the rest.
struct LAAMacListDetail<List: View, Detail: View>: View {
    var listWidth: CGFloat = LAADesktopMetrics.listIdealWidth
    @ViewBuilder var list: () -> List
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        // A set width rather than a min–max range: in a stack a range takes
        // its maximum, which left every list at its widest.
        GeometryReader { proxy in
            HStack(spacing: 0) {
                list()
                    .frame(width: LAADesktopMetrics.listWidth(listWidth, available: proxy.size.width))
                    .frame(maxHeight: .infinity)
                    .background(LAAColor.background)
                Rectangle()
                    .fill(LAAColor.separator)
                    .frame(width: 1)
                    .accessibilityHidden(true)
                detail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LAAColor.surface)
            }
        }
    }
}

/// Shown in a detail column before anything is selected.
struct LAAMacEmptyDetail: View {
    let symbol: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: LAASpacing.x3) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LAAColor.secondaryText)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(LAAType.employeeName)
                .foregroundStyle(LAAColor.text)
            if let message {
                Text(verbatim: message)
                    .laaTextStyle(.secondary)
                    .foregroundStyle(LAAColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(LAASpacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Centers content at a comfortable line length in a wide column.
    func laaReadableWidth(_ width: CGFloat = LAADesktopMetrics.documentWidth) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }

    /// A page's text column: on the phone a leading column up to `phone`
    /// points, on the Mac centred at `desktop`, so a wide window never shows
    /// a phone-width column with empty paper beside it.
    func laaPageWidth(phone: CGFloat = 720, desktop: CGFloat = LAADesktopMetrics.documentWidth) -> some View {
        modifier(LAAPageWidth(phone: phone, desktop: desktop))
    }

    /// A sheet's size on the Mac. Catalyst otherwise shows every sheet as a
    /// small form sheet (about 415×477 Mac points) whatever its detents say.
    /// The phone keeps its detents; this does nothing there.
    func laaSheetSize(_ size: LAASheetSize) -> some View {
        modifier(LAASheetSizing(size: size))
    }
}

/// Sheet sizes in UIKit points (Mac points ≈ ×0.77).
enum LAASheetSize {
    /// Settings, connection, notifications: ≈ 800×600 Mac points.
    case settings
    /// Create or edit one thing: a task, a project, a session.
    case form
    /// A short choice: a model, a profile, an order.
    case picker
    /// Reading or a call: ≈ 700×650 Mac points.
    case page

    var width: CGFloat {
        switch self {
        case .settings: 1040
        case .form: 680
        case .picker: 520
        case .page: 900
        }
    }

    var height: CGFloat {
        switch self {
        case .settings: 780
        case .form: 600
        case .picker: 480
        case .page: 840
        }
    }
}

private struct LAAPageWidth: ViewModifier {
    @Environment(\.laaDesktop) private var laaDesktop
    let phone: CGFloat
    let desktop: CGFloat

    func body(content: Content) -> some View {
        if laaDesktop {
            content.frame(maxWidth: desktop, alignment: .leading).frame(maxWidth: .infinity)
        } else {
            content.frame(maxWidth: phone, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LAASheetSizing: ViewModifier {
    let size: LAASheetSize

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            content
                .frame(minWidth: size.width * 0.8, idealWidth: size.width,
                       minHeight: size.height * 0.75, idealHeight: size.height)
                .presentationSizing(.fitted)
        } else {
            content.frame(minWidth: size.width, minHeight: size.height)
        }
        #else
        content
        #endif
    }
}
#endif
