#if LAA_BUILD
import SwiftUI
import LAAKit

/// Equal segments while they fit; otherwise scroll the current one into view.
/// At accessibility sizes, use two rows.
struct LAAWorkSectionSelector: View {
    typealias Section = LAAWorkHub.Section
    @Binding var selection: Section
    let decisions: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.laaDesktop) private var desktop

    static let sections: [Section] = Section.allCases
    private var hit: CGFloat { desktop ? LAAControl.Mac.hitArea : LAAControl.IPhone.hitArea }
    private var control: LAAControlSize { desktop ? LAAControl.Mac.secondary : LAAControl.IPhone.compact }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    row(Self.sections.prefix(2), equal: true)
                    row(Self.sections.suffix(2), equal: true)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    row(Self.sections[...], equal: true)
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) {
                            row(Self.sections[...], equal: false)
                        }
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        .onAppear { reader.scrollTo(selection, anchor: .center) }
                        .onChange(of: selection) { _, now in
                            withAnimation(.snappy) { reader.scrollTo(now, anchor: .center) }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.segment")
    }

    private func row(_ sections: ArraySlice<Section>, equal: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(sections) { section in
                let selected = selection == section
                Button { selection = section } label: {
                    Text(verbatim: section.title)
                        .laaFont(control.label, weight: selected ? .semibold : .medium)
                        .foregroundStyle(selected ? LAAColor.link : LAAColor.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, LAASpace.s8)
                        .frame(maxWidth: equal ? .infinity : nil, minHeight: hit)
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
                .id(section)
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

    private var countMark: some View {
        Circle().fill(LAAColor.link)
            .frame(width: LAASpace.s4, height: LAASpace.s4)
            .padding(.bottom, LAASpace.s4)
            .accessibilityHidden(true)
    }

    private func count(_ section: Section) -> Int {
        section == .decisions ? decisions : 0
    }

    private func label(_ section: Section) -> String {
        let number = count(section)
        return number > 0 ? "\(section.title) \(number)" : section.title
    }
}
#endif
