#if LAA_BUILD
import SwiftUI
import LAAKit

/// Four frequent destinations. On iPhone, swipe to the remaining sections
/// or use the same menu as Mac and accessibility text sizes.
struct LAAWorkSectionSelector: View {
    typealias Section = LAAWorkHub.Section
    @Binding var selection: Section
    let decisions: Int
    let campaigns: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.laaDesktop) private var desktop

    private static let primary: [Section] = [.projects, .sessions, .decisions, .tasks]
    private static let secondary: [Section] = [.routines, .campaigns]
    private var hit: CGFloat { desktop ? LAAControl.Mac.hitArea : LAAControl.IPhone.hitArea }
    private var control: LAAControlSize { desktop ? LAAControl.Mac.secondary : LAAControl.IPhone.compact }

    var body: some View {
        if desktop || typeSize.isAccessibilitySize {
            HStack(spacing: LAASpace.s4) {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        row(Self.primary.prefix(2))
                        row(Self.primary.suffix(2))
                    }
                } else {
                    row(Self.primary[...])
                }
                overflow
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("work.segment")
        } else {
            HStack(spacing: LAASpace.s4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        row(Self.primary[...]).containerRelativeFrame(.horizontal)
                        row(Self.secondary[...]).containerRelativeFrame(.horizontal)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .accessibilityIdentifier("work.segment")
                overflow
            }
        }
    }

    private func row(_ sections: ArraySlice<Section>) -> some View {
        HStack(spacing: 0) {
            ForEach(sections) { section in
                let selected = selection == section
                Button { selection = section } label: {
                    Text(verbatim: section.title)
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, LAASpace.s4)
                        .frame(maxWidth: .infinity, minHeight: hit)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: control.radius)
                                    .fill(LAAColor.selectionFill).frame(height: typeSize.isAccessibilitySize ? nil : control.height)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if count(section) > 0 { countMark }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: label(section)))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("work.section.\(section.rawValue)")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: control.radius)
                .fill(.clear)
                .frame(height: typeSize.isAccessibilitySize ? nil : control.height)
                .laaGlass(in: RoundedRectangle(cornerRadius: control.radius), interactive: false, tinted: false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var overflow: some View {
        let selected = Self.secondary.contains(selection)
        return Menu {
            ForEach(Self.secondary) { section in
                LAAWorkPickerItem(title: label(section), selected: selection == section,
                                  identifier: "work.section.\(section.rawValue)") { selection = section }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                .frame(width: hit, height: hit)
                .overlay(alignment: .bottom) {
                    if campaigns > 0 { countMark }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "More"))
        .accessibilityValue(Text(verbatim: selected ? label(selection) : (campaigns > 0 ? label(.campaigns) : "")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("work.section.more")
    }

    private var countMark: some View {
        Circle().fill(LAAColor.link)
            .frame(width: LAASpace.s4, height: LAASpace.s4)
            .padding(.bottom, LAASpace.s4)
            .accessibilityHidden(true)
    }

    private func count(_ section: Section) -> Int {
        switch section {
        case .decisions: decisions
        case .campaigns: campaigns
        default: 0
        }
    }

    private func label(_ section: Section) -> String {
        let number = count(section)
        return number > 0 ? "\(section.title) \(number)" : section.title
    }
}
#endif
