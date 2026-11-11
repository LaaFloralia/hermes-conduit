#if LAA_BUILD
import XCTest
@testable import Conduit

/// The Mac's split panes for Work › Sessions, as data: what each operation
/// does to the tree, the frames it lays out, and where keyboard focus moves.
final class LAAWorkPaneLayoutTests: XCTestCase {
    private func ids(_ layout: LAAWorkPaneLayout) -> [String?] { layout.panes.map(\.sessionID) }

    func testStartsWithOneEmptyFocusedPane() {
        let layout = LAAWorkPaneLayout()
        XCTAssertEqual(layout.panes.count, 1)
        XCTAssertEqual(layout.focusedID, layout.panes[0].id)
        XCTAssertNil(layout.focused?.sessionID)
    }

    func testOpeningFillsTheFocusedPaneAndNeverShowsASessionTwice() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        let second = layout.split(edge: .trailing, sessionID: "b")
        XCTAssertNotNil(second)
        XCTAssertEqual(ids(layout), ["a", "b"])
        XCTAssertEqual(layout.focusedID, second)
        // "a" is already on screen: its pane takes the focus, nothing changes.
        layout.open("a")
        XCTAssertEqual(ids(layout), ["a", "b"])
        XCTAssertEqual(layout.focused?.sessionID, "a")
        // A new session replaces the focused pane's.
        layout.open("c")
        XCTAssertEqual(ids(layout), ["c", "b"])
    }

    func testSplitPlacesTheNewPaneOnTheRequestedEdge() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .leading, sessionID: "b")
        XCTAssertEqual(ids(layout), ["b", "a"])
        layout.split(layout.panes[1].id, edge: .bottom, sessionID: "c")
        XCTAssertEqual(ids(layout), ["b", "a", "c"])
        guard case .split(let root) = layout.root, case .split(let right) = root.second else {
            return XCTFail("expected a column split holding a stacked split")
        }
        XCTAssertEqual(root.axis, .horizontal)
        XCTAssertEqual(right.axis, .vertical)
    }

    func testSplittingWithASessionShownElsewhereMovesIt() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .trailing, sessionID: "a")
        XCTAssertEqual(ids(layout), [nil, "a"])
    }

    func testSplitStopsAtTheMaximum() {
        var layout = LAAWorkPaneLayout()
        for index in 1..<LAAWorkPaneLayout.maximumPanes { XCTAssertNotNil(layout.split(sessionID: "s\(index)")) }
        XCTAssertEqual(layout.panes.count, LAAWorkPaneLayout.maximumPanes)
        XCTAssertFalse(layout.canSplit)
        XCTAssertNil(layout.split(sessionID: "extra"))
        XCTAssertEqual(layout.panes.count, LAAWorkPaneLayout.maximumPanes)
    }

    func testClosingLiftsTheSiblingAndFocusesItsNeighbour() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .trailing, sessionID: "b")
        layout.split(edge: .bottom, sessionID: "c")
        layout.close()
        XCTAssertEqual(ids(layout), ["a", "b"])
        XCTAssertEqual(layout.focused?.sessionID, "b")
        layout.close()
        XCTAssertEqual(ids(layout), ["a"])
        guard case .pane = layout.root else { return XCTFail("one pane should be the whole tree again") }
        // The last pane stays and only empties.
        layout.close()
        XCTAssertEqual(ids(layout), [nil])
    }

    func testPlaceTradesWithThePaneThatAlreadyShowsTheSession() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .trailing, sessionID: "b")
        layout.place("a", in: layout.panes[1].id)
        XCTAssertEqual(ids(layout), ["b", "a"])
        layout.place("c", in: layout.panes[0].id)
        XCTAssertEqual(ids(layout), ["c", "a"])
        XCTAssertEqual(layout.focusedID, layout.panes[0].id)
    }

    func testSwapExchangesContentAndKeepsTheArrangement() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .bottom, sessionID: "b")
        let before = layout.panes.map(\.id)
        layout.swap(before[0], before[1])
        XCTAssertEqual(layout.panes.map(\.id), before)
        XCTAssertEqual(ids(layout), ["b", "a"])
    }

    func testMovePutsAPaneAtAnotherPanesEdge() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .trailing, sessionID: "b")
        layout.split(edge: .trailing, sessionID: "c")
        let c = layout.panes[2].id
        layout.move(c, to: layout.panes[0].id, edge: .top)
        XCTAssertEqual(ids(layout), ["c", "a", "b"])
        XCTAssertEqual(layout.focusedID, c)
        // A pane can't be moved onto itself or out of a one-pane tree.
        var single = LAAWorkPaneLayout()
        single.move(single.focusedID, to: single.focusedID, edge: .leading)
        XCTAssertEqual(single.panes.count, 1)
    }

    func testFramesFillTheAreaAndLeaveTheGap() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .trailing, sessionID: "b")
        layout.split(edge: .bottom, sessionID: "c")
        let frames = LAAWorkPaneLayout.frames(layout.root, in: CGRect(x: 0, y: 0, width: 1001, height: 601), gap: 1)
        let panes = layout.panes.map(\.id)
        XCTAssertEqual(frames[panes[0]], CGRect(x: 0, y: 0, width: 500, height: 601))
        XCTAssertEqual(frames[panes[1]], CGRect(x: 501, y: 0, width: 500, height: 300))
        XCTAssertEqual(frames[panes[2]], CGRect(x: 501, y: 301, width: 500, height: 300))
        let dividers = LAAWorkPaneLayout.dividers(layout.root, in: CGRect(x: 0, y: 0, width: 1001, height: 601), gap: 1)
        XCTAssertEqual(dividers.map(\.rect), [CGRect(x: 500, y: 0, width: 1, height: 601),
                                              CGRect(x: 501, y: 300, width: 500, height: 1)])
    }

    func testDraggingADividerKeepsBothSidesAboveTheMinimum() {
        let divider = LAAWorkPaneLayout.Divider(splitID: "s", axis: .horizontal,
                                                rect: CGRect(x: 500, y: 0, width: 1, height: 600),
                                                parent: CGRect(x: 0, y: 0, width: 1001, height: 600))
        XCTAssertEqual(LAAWorkPaneLayout.ratio(for: CGPoint(x: 700, y: 10), divider: divider, minimum: 100), 0.7, accuracy: 0.001)
        XCTAssertEqual(LAAWorkPaneLayout.ratio(for: CGPoint(x: 10, y: 10), divider: divider, minimum: 340), 0.34, accuracy: 0.001)
        XCTAssertEqual(LAAWorkPaneLayout.ratio(for: CGPoint(x: 990, y: 10), divider: divider, minimum: 100), 0.85, accuracy: 0.001)
        var layout = LAAWorkPaneLayout()
        layout.split(sessionID: "b")
        guard case .split(let split) = layout.root else { return XCTFail("expected a split") }
        layout.setRatio(split.id, 2)
        guard case .split(let clamped) = layout.root else { return XCTFail("expected a split") }
        XCTAssertEqual(clamped.ratio, LAAWorkPaneLayout.ratioRange.upperBound)
    }

    func testEqualizeGivesThreeColumnsThirds() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .trailing, sessionID: "b")
        layout.split(edge: .trailing, sessionID: "c")
        layout.equalize()
        let frames = LAAWorkPaneLayout.frames(layout.root, in: CGRect(x: 0, y: 0, width: 902, height: 400), gap: 1)
        let widths = layout.panes.compactMap { frames[$0.id]?.width }
        XCTAssertEqual(widths.count, 3)
        for width in widths { XCTAssertEqual(width, 300, accuracy: 1) }
    }

    func testDirectionalFocusPicksTheNeighbourOnThatSide() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .trailing, sessionID: "b")
        layout.split(edge: .bottom, sessionID: "c")
        let frames = LAAWorkPaneLayout.frames(layout.root, in: CGRect(x: 0, y: 0, width: 1001, height: 601))
        let panes = layout.panes.map(\.id)
        XCTAssertEqual(LAAWorkPaneLayout.neighbor(of: panes[2], direction: .up, frames: frames), panes[1])
        XCTAssertEqual(LAAWorkPaneLayout.neighbor(of: panes[2], direction: .left, frames: frames), panes[0])
        XCTAssertEqual(LAAWorkPaneLayout.neighbor(of: panes[0], direction: .right, frames: frames), panes[1])
        XCTAssertNil(LAAWorkPaneLayout.neighbor(of: panes[0], direction: .left, frames: frames))
        XCTAssertNil(LAAWorkPaneLayout.neighbor(of: panes[1], direction: .up, frames: frames))
        layout.focus(.left, frames: frames)
        XCTAssertEqual(layout.focusedID, panes[0])
    }

    func testNextAndPreviousWrapInReadingOrder() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(sessionID: "b")
        layout.split(sessionID: "c")
        layout.focusNext(1)
        XCTAssertEqual(layout.focused?.sessionID, "a")
        layout.focusNext(-1)
        XCTAssertEqual(layout.focused?.sessionID, "c")
    }

    func testZoomFollowsFocusAndEndsWithASplit() {
        var layout = LAAWorkPaneLayout()
        layout.toggleZoom()
        XCTAssertNil(layout.zoomedID, "one pane has nothing to zoom over")
        layout.open("a")
        layout.split(sessionID: "b")
        layout.toggleZoom()
        XCTAssertEqual(layout.zoomedID, layout.focusedID)
        layout.focusNext(1)
        XCTAssertEqual(layout.zoomedID, layout.focusedID)
        layout.split(sessionID: "c")
        XCTAssertNil(layout.zoomedID)
    }

    func testDropEdgeIsTheNearestQuarter() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(LAAWorkPaneLayout.dropEdge(at: CGPoint(x: 20, y: 150), in: size), .leading)
        XCTAssertEqual(LAAWorkPaneLayout.dropEdge(at: CGPoint(x: 390, y: 150), in: size), .trailing)
        XCTAssertEqual(LAAWorkPaneLayout.dropEdge(at: CGPoint(x: 200, y: 10), in: size), .top)
        XCTAssertEqual(LAAWorkPaneLayout.dropEdge(at: CGPoint(x: 200, y: 290), in: size), .bottom)
        XCTAssertNil(LAAWorkPaneLayout.dropEdge(at: CGPoint(x: 200, y: 150), in: size))
        XCTAssertNil(LAAWorkPaneLayout.dropEdge(at: .zero, in: .zero))
    }

    func testForgetEmptiesPanesWhoseSessionIsGone() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(sessionID: "b")
        layout.forget(sessionsNotIn: ["b"])
        XCTAssertEqual(ids(layout), [nil, "b"])
    }

    func testSavedLayoutRoundTripsAndDamagedValuesStartOver() {
        var layout = LAAWorkPaneLayout()
        layout.open("a")
        layout.split(edge: .bottom, sessionID: "b")
        layout.toggleZoom()
        let restored = LAAWorkPaneLayout.decoded(layout.encoded)
        XCTAssertEqual(restored, layout)
        // New ids after a relaunch don't collide with the saved ones.
        var next = restored
        let id = next.split(sessionID: "c")
        XCTAssertEqual(Set(next.panes.map(\.id)).count, 3)
        XCTAssertNotNil(id)
        XCTAssertEqual(LAAWorkPaneLayout.decoded("not json"), LAAWorkPaneLayout())
        XCTAssertEqual(LAAWorkPaneLayout.decoded(""), LAAWorkPaneLayout())
    }
}
#endif
