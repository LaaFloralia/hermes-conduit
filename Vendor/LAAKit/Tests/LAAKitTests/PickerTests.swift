#if !os(watchOS)
import LAATokens
import QuartzCore
import SwiftUI
import Testing
@testable import LAAKit

struct PickerTests {
    @Test func suppliedTierSelectsTheHortensiaModelTokens() {
        let models: [(LAAPickerModel.Tier, LAAAppSelection.Model, LAAMarbleStep)] = [
            (.mythos, LAAAppSelection.mythos, .model),
            (.astra, LAAAppSelection.astra, .model),
            (.neon, LAAAppSelection.neon, .model),
            (.stone, LAAAppSelection.stone, .plain),
            (.plain, LAAAppSelection.stone, .plain),
        ]
        for (tier, tokens, step) in models {
            let model = LAAPickerModel(id: "opaque-id", displayName: "Caller-supplied name", tier: tier)
            #expect(model.tier.tokens == tokens)
            #expect(model.tier.modelStep == step)
        }
        let intentionallyPlain = LAAPickerModel(id: "mythos", displayName: "Claude Mythos", tier: .plain)
        #expect(intentionallyPlain.tier.modelStep == .plain)
    }

    @Test func effortMapsOnlyAdoptedIDsToMarbleSteps() {
        let steps: [(String?, LAAMarbleStep, LAAAppSelection.Step)] = [
            (nil, .plain, LAAAppSelection.plainStep),
            ("low", .plain, LAAAppSelection.plainStep),
            ("medium", .plain, LAAAppSelection.plainStep),
            ("high", .plain, LAAAppSelection.plainStep),
            ("XHigh", .plain, LAAAppSelection.plainStep),
            ("model", .plain, LAAAppSelection.plainStep),
            ("xhigh", .xhigh, LAAAppSelection.xhighStep),
            ("max", .max, LAAAppSelection.maxStep),
            ("ultracode", .ultracode, LAAAppSelection.ultracodeStep),
        ]
        for (id, step, tokens) in steps {
            #expect(LAAMarbleStep.effort(id) == step)
            #expect(step.tokens == tokens)
        }
        #expect(LAAMarbleStep.model.tokens == LAAAppSelection.modelStep)
    }

    @Test func intensityDensityAndCrossingFollowAdoptedFormula() {
        let xhigh = LAAMarbleStyle(tier: .mythos, step: .xhigh)
        let max = LAAMarbleStyle(tier: .mythos, step: .max)
        let ultra = LAAMarbleStyle(tier: .mythos, step: .ultracode)
        #expect(xhigh.intensity < max.intensity && max.intensity < ultra.intensity)
        #expect(xhigh.tileSize.width > max.tileSize.width && max.tileSize.width > ultra.tileSize.width)
        #expect(xhigh.crossingSeconds > max.crossingSeconds && max.crossingSeconds > ultra.crossingSeconds)
        #expect(ultra.lightOpacity(dark: true) == 1)
        let mythos = LAAMarbleStyle(tier: .mythos, step: .model)
        let astra = LAAMarbleStyle(tier: .astra, step: .model)
        let neon = LAAMarbleStyle(tier: .neon, step: .model)
        #expect(mythos.intensity > astra.intensity && astra.intensity == neon.intensity)
        #expect(neon.model != astra.model)
        #expect(LAAMarbleStyle(tier: .plain, step: .max).model == LAAAppSelection.stone)
        #expect(LAAMarbleStyle(tier: .neon, step: .plain).isPlain)
        let band = LAAMarble.labelBand(width: 100)
        #expect(band.locations == band.locations.sorted())
        #expect(band.opacities[3...4].allSatisfy { $0 == LAAAppSelection.labelBandChevron })
    }

    @Test func ceremonyOnlyFollowsAnAppliedChangeRequestedByThisControl() {
        var view = LAACeremonyTrigger()
        let time = Date(timeIntervalSinceReferenceDate: 100)
        func value(_ id: String, _ changing: Bool = false) -> LAACeremonyTrigger.Input { .init(id: id, changing: changing) }
        view.update(from: value("a"), to: value("b"), now: time, enabled: true)
        #expect(view.start == nil)
        view.update(from: value("b"), to: value("b", true), now: time, enabled: true)
        view.update(from: value("b", true), to: value("c", true), now: time, enabled: true)
        #expect(view.start == nil)
        view.update(from: value("c", true), to: value("c"), now: time, enabled: true)
        #expect(view.start == time)
        view.update(from: value("c"), to: value("c", true), now: time, enabled: true)
        view.update(from: value("c", true), to: value("d"), now: time, enabled: false)
        #expect(view.start == nil)
        view.update(from: value("d"), to: value("d", true), now: time, enabled: true)
        view.update(from: value("d", true), to: value("d"), now: time, enabled: true)
        let applied = time.addingTimeInterval(1)
        view.update(from: value("d"), to: value("e"), now: applied, enabled: true)
        #expect(view.start == applied)
    }

    @Test @MainActor func bundledTilesAndRenderServerMotion() throws {
        let model = LAAAppSelection.astra
        for asset in [LAAAppSelection.assetCloud, LAAAppSelection.assetMain, LAAAppSelection.assetHair] {
            for scale in 1...3 {
                let image = try #require(LAAMarbleAssets.source(asset, scale: scale))
                #expect(image.width == Int(LAAAppSelection.tileWidthPt) * scale)
                #expect(image.height == Int(LAAAppSelection.tileHeightPt) * scale)
                let tile = try #require(LAAMarbleAssets.tile(asset, color: model.ink.dark, scale: CGFloat(scale)))
                #expect(tile.width == image.width && tile.height == image.height)
            }
        }
        let root = CALayer()
        let layers = LAAMarbleLayers(root: root)
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 36)
        let style = LAAMarbleStyle(tier: .astra, step: .max)
        func animate(_ moving: Bool, visible: Bool, start: Date? = nil) {
            layers.update(.init(style: style, seed: LAAMarble.seed("max"), dark: true, moves: moving, start: start),
                          bounds: bounds, scale: 2, attached: visible)
        }
        func animations(_ layer: CALayer) -> [String] {
            (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap { animations($0) }
                + (layer.mask.map { animations($0) } ?? [])
        }
        animate(false, visible: true)
        #expect(animations(root).isEmpty)
        animate(true, visible: true)
        #expect(animations(root).filter { $0 == "laa.marble.drift" }.count == 2)
        let appliedAt = Date()
        animate(true, visible: true, start: appliedAt)
        #expect(animations(root).filter { $0 == "laa.marble.front" }.count == 3)
        let spread = try #require(root.sublayers?.first?.mask?.animation(forKey: "laa.marble.front") as? CABasicAnimation)
        #expect(spread.fromValue as? Double == LAAAppSelection.frontFrom * bounds.width)
        #expect(spread.toValue as? Double == LAAAppSelection.frontTo * bounds.width)
        #expect(spread.duration == LAAAppSelection.selectionSeconds)
        animate(true, visible: false, start: appliedAt)
        #expect(animations(root).isEmpty)
        animate(true, visible: true, start: appliedAt)
        #expect(!animations(root).contains("laa.marble.front"))
    }

    @Test func wrapMovesEffortInsteadOfTruncatingModel() {
        let widths: [CGFloat] = [144, 78]
        #expect(LAAWrapRow.lines(widths, available: 230, spacing: 8) == [0, 0])
        #expect(LAAWrapRow.lines(widths, available: 229, spacing: 8) == [0, 1])
    }
}
#endif
