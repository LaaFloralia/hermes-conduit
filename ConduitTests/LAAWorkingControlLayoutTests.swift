#if LAA_BUILD && DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// The working capsule's words and sizes (D-21 C, 2026-11-27): English
/// copy, small while thinking and large while agents run (three rows, then
/// `+N`), content width, and no clipping at the largest text size.
@MainActor
final class LAAWorkingControlLayoutTests: XCTestCase {
    private func child(_ id: String, _ state: LAAWorkingChild.State, title: String? = nil,
                       meta: String? = "Opus 5.5 · High") -> LAAWorkingChild {
        LAAWorkingChild(id: id, title: title ?? "Agent \(id)", state: state, meta: meta)
    }

    // MARK: Copy

    func testCopyIsEnglish() {
        XCTAssertEqual(LAAWorkingCopy.agents(1), "Agent 1")
        XCTAssertEqual(LAAWorkingCopy.agents(3), "Agents 3")
        XCTAssertEqual(LAAWorkingCopy.open(1), "Open agent")
        XCTAssertEqual(LAAWorkingCopy.open(5), "Open agents")
        XCTAssertEqual(LAAWorkingCopy.more(2), "+2")
        XCTAssertEqual(LAAWorkingCopy.jumpToLatest, "Jump to latest")
        let words = [LAAWorkingChild.State.running, .attention, .waiting, .failed, .done].map { child("x", $0).word }
        XCTAssertEqual(words, ["Running", "Decision", "Waiting", "Failed", "Done"])
        for text in [LAAWorkingCopy.agents(1), LAAWorkingCopy.agents(4), LAAWorkingCopy.open(1), LAAWorkingCopy.open(2),
                     LAAWorkingCopy.jumpToLatest] + words {
            XCTAssertNil(text.range(of: "\\p{Han}|\\p{Hiragana}|\\p{Katakana}", options: .regularExpression), text)
        }
    }

    func testChildPrefixIsDroppedOnScreenOnly() {
        XCTAssertEqual(LAAWorkingCopy.displayName("子｜Hortensia｜Session下部"), "Hortensia｜Session下部")
        XCTAssertEqual(LAAWorkingCopy.displayName("子|Build"), "Build")
        XCTAssertEqual(LAAWorkingCopy.displayName("子｜ Build"), "Build")
        XCTAssertEqual(LAAWorkingCopy.displayName("Build 子｜x"), "Build 子｜x", "Only a leading prefix")
        XCTAssertEqual(LAAWorkingCopy.displayName("子｜"), "子｜", "Nothing left: the name stays")
        let row = child("a", .running, title: "子｜Read the folder")
        XCTAssertEqual(row.displayTitle, "Read the folder")
        XCTAssertEqual(row.title, "子｜Read the folder", "The name itself is unchanged")
    }

    func testElapsedIsMinutesAndSeconds() {
        XCTAssertEqual(LAAWorkingCopy.elapsed(0), "0:00")
        XCTAssertEqual(LAAWorkingCopy.elapsed(42.9), "0:42")
        XCTAssertEqual(LAAWorkingCopy.elapsed(725), "12:05")
        XCTAssertEqual(LAAWorkingCopy.elapsed(3729), "1:02:09")
        XCTAssertEqual(LAAWorkingCopy.elapsed(-5), "0:00")
    }

    // MARK: Layout

    func testNoChildrenIsTheSmallCapsule() {
        let layout = LAAWorkingLayout(children: [])
        XCTAssertEqual(layout.size, .small)
        XCTAssertEqual(layout.rows.count, 0)
        XCTAssertNil(layout.countText)
        XCTAssertNil(layout.moreText)
        XCTAssertEqual(layout.lines, 0)
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(layout.height(), 36)
        XCTAssertEqual(layout.hitExtent(), 44)
        XCTAssertEqual(LAAWorkingControlMetrics.coverage(children: 0), 52)
        #endif
    }

    func testOneChildIsLargeWithOneRow() {
        let layout = LAAWorkingLayout(children: [child("a", .running)])
        XCTAssertEqual(layout.size, .large)
        XCTAssertEqual(layout.rows.map(\.id), ["a"])
        XCTAssertEqual(layout.countText, "Agent 1")
        XCTAssertNil(layout.moreText)
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(layout.height(), 36 + 20 + 12)
        #endif
    }

    func testThreeChildrenShowAllRows() {
        let layout = LAAWorkingLayout(children: [child("a", .running), child("b", .waiting), child("c", .attention)])
        XCTAssertEqual(layout.rows.map(\.id), ["c", "a", "b"], "▲ first, then ●, then ○")
        XCTAssertEqual(layout.overflow, 0)
        XCTAssertEqual(layout.countText, "Agents 3")
        XCTAssertEqual(layout.lines, 3)
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(layout.height(), 36 + 3 * 20 + 2 * 4 + 12)
        #endif
    }

    func testFiveChildrenShowThreeRowsAndPlusTwo() {
        let five = [child("a", .waiting), child("b", .running), child("c", .failed), child("d", .done), child("e", .attention)]
        let layout = LAAWorkingLayout(children: five)
        XCTAssertEqual(layout.rows.map(\.id), ["c", "e", "b"], "The most urgent three; ties keep their order")
        XCTAssertEqual(layout.overflow, 2)
        XCTAssertEqual(layout.moreText, "+2")
        XCTAssertEqual(layout.countText, "Agents 5")
        XCTAssertEqual(layout.lines, 4)
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(layout.height(), 36 + 4 * 20 + 3 * 4 + 12)
        #endif
        XCTAssertEqual(LAAWorkingLayout(count: 5), LAAWorkingLayout(count: 5))
        XCTAssertEqual(LAAWorkingLayout(count: 5).height(), layout.height(), "The transcript's room matches the drawn capsule")
        XCTAssertEqual(LAAWorkingControlMetrics.coverage(children: 5),
                       layout.hitExtent() + LAAWorkingControlMetrics.gapAboveComposer)
    }

    func testTextGrowsWithDynamicTypeAndHolds() {
        #if !targetEnvironment(macCatalyst)
        let layout = LAAWorkingLayout(count: 3)
        XCTAssertGreaterThan(layout.height(typeSize: .accessibility2), layout.height(typeSize: .large))
        XCTAssertEqual(layout.height(typeSize: .accessibility5), layout.height(typeSize: .accessibility2),
                       "Held at accessibility2")
        XCTAssertEqual(LAAWorkingLayout.scaled(13, .large), 13, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(LAAWorkingLayout.topHeight(.xSmall), 36, "Never under the control height")
        #endif
    }

    // MARK: Drawn width

    /// The capsule takes its content's width, centred, never the full row;
    /// at the largest text the drawn height is the layout's (nothing clips).
    func testCapsuleTakesItsContentWidth() throws {
        let start = Date().addingTimeInterval(-42)
        let small = try fittedSize(LAAWorkingStatus(word: "Thinking", startedAt: start), width: 440)
        XCTAssertLessThan(small.width, 200, "Thinking alone is small: \(small)")
        XCTAssertEqual(small.height, LAAWorkingLayout(count: 0).hitExtent(), accuracy: 0.5)
        let names = ["子｜Hortensia｜Session下部の表示を直して撮影まで済ませる長い名前", "Check the build", "Write the notes"]
        let three = names.enumerated().map { child(String($0.offset), .running, title: $0.element) }
        for (typeSize, width) in [(DynamicTypeSize.large, CGFloat(440)), (.accessibility5, 375)] {
            let size = try fittedSize(LAAWorkingStatus(word: "Thinking", startedAt: start, children: three), width: width,
                                      typeSize: typeSize)
            XCTAssertLessThanOrEqual(size.width, width, "\(typeSize)")
            XCTAssertGreaterThan(size.width, small.width)
            XCTAssertEqual(size.height, LAAWorkingLayout(count: 3).hitExtent(typeSize: typeSize), accuracy: 0.5, "\(typeSize)")
        }
    }

    private func fittedSize(_ status: LAAWorkingStatus, width: CGFloat, typeSize: DynamicTypeSize = .large) throws -> CGSize {
        let host = UIHostingController(rootView: LAAWorkingPill(status: status, openChildren: {})
            .environment(\.dynamicTypeSize, typeSize))
        return host.sizeThatFits(in: CGSize(width: width, height: 1000))
    }

    func testStatesAreDrawnAtPhoneAndSEWidths() throws {
        let start = Date().addingTimeInterval(-42)
        let five = [
            child("a", .running, title: "子｜Hortensia｜Session下部の表示を直す"),
            child("b", .attention, title: "Read the build log and report the failures", meta: "GPT 6.2 Sol · High"),
            child("c", .waiting, title: "文言の置換表をまとめる", meta: "Gemini 4 Neon"),
            child("d", .failed, title: "Check the tab bar glass", meta: "GPT 6.2 Sol"),
            child("e", .waiting, title: "Usage storage", meta: "DeepSeek V4.1 Flash"),
        ]
        let states: [(String, LAAWorkingStatus)] = [
            ("thinking", LAAWorkingStatus(word: "Thinking", startedAt: start)),
            ("three", LAAWorkingStatus(word: "作業中", startedAt: start, orb: .tool, children: Array(five.prefix(3)))),
            ("five", LAAWorkingStatus(word: "作業中", startedAt: start, orb: .tool, children: five)),
        ]
        for width in [CGFloat(440), 375] {
            for typeSize in [DynamicTypeSize.large, .accessibility5] {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    for (name, status) in states {
                        let image = try render(width: width, height: 340, style: style, typeSize: typeSize) {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                LAAWorkingCluster(status: status, showsJump: name == "five", jump: {}, openChildren: {}) {
                                    RoundedRectangle(cornerRadius: 22).fill(LAAColor.surface).frame(height: 52)
                                        .padding(.horizontal, 16)
                                }
                                .padding(.bottom, 12)
                            }
                        }
                        attach(image, name: "layout-\(name)-\(Int(width))-\(typeSize == .large ? "default" : "ax5")-\(style == .dark ? "dark" : "light")")
                    }
                }
            }
        }
    }

    private func render<V: View>(width: CGFloat, height: CGFloat, style: UIUserInterfaceStyle, typeSize: DynamicTypeSize,
                                 @ViewBuilder _ content: () -> V) throws -> UIImage {
        let root = content()
            .frame(width: width, height: height, alignment: .top)
            .background(LAAColor.background)
            .environment(\.colorScheme, style == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, typeSize)
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<8 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
