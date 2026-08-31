import XCTest
@testable import OpenGlasses

final class DockLayoutTests: XCTestCase {

    func testEmptyStoredYieldsCanonical() {
        XCTAssertEqual(DockLayout.effectiveOrder(stored: []), DockLayout.canonical)
        XCTAssertEqual(DockLayout.decode(""), DockLayout.canonical)
    }

    func testStoredOrderWinsAndMissingItemsAppendCanonically() {
        // User moved mic mode first and disconnect second; everything they
        // never touched follows in shipped order.
        let order = DockLayout.effectiveOrder(stored: ["micMode", "disconnect"])
        XCTAssertEqual(Array(order.prefix(2)), [.micMode, .disconnect])
        XCTAssertEqual(
            Array(order.dropFirst(2)),
            DockLayout.canonical.filter { $0 != .micMode && $0 != .disconnect }
        )
        XCTAssertEqual(Set(order), Set(DockItem.allCases))
    }

    func testStaleAndDuplicateIdentifiersAreDropped() {
        let order = DockLayout.effectiveOrder(
            stored: ["camera", "retiredButton", "camera", "model"])
        XCTAssertEqual(Array(order.prefix(2)), [.camera, .model])
        XCTAssertEqual(order.count, DockItem.allCases.count)
    }

    func testEncodeDecodeRoundTrip() {
        let shuffled: [DockItem] = [.disconnect, .camera, .model,
                                    .preview, .type, .micMode, .assistive]
        XCTAssertEqual(DockLayout.decode(DockLayout.encode(shuffled)), shuffled)
    }

    // MARK: - Model tile mark

    /// The tile prefers a bundled brand mark and falls back to a symbol. The fallback is the part
    /// that must never have a hole in it: no asset ships today, so every provider is drawn by this
    /// mapping, and the switch is exhaustive precisely so a new provider cannot slip through on a
    /// `default` clause.
    func testEveryProviderHasASymbolFallback() {
        for provider in LLMProvider.allCases {
            XCTAssertFalse(DockLayout.modelTileGlyph(for: provider).isEmpty,
                           "\(provider.rawValue) has no fallback glyph")
        }
    }

    /// Distinct enough to tell the big three apart at a glance — the reason the tile stopped
    /// carrying the model's name in the first place.
    func testTheMajorProvidersDoNotShareAGlyph() {
        let marks = [LLMProvider.anthropic, .openai, .gemini].map(DockLayout.modelTileGlyph(for:))
        XCTAssertEqual(Set(marks).count, marks.count, "Two major providers draw the same glyph")
    }

    /// The asset name is the whole contract with whoever drops a brand mark into the catalog.
    func testProviderMarkAssetNamesAreKeyedToTheProvidersRawValue() {
        XCTAssertEqual(DockLayout.providerMarkAsset(for: .anthropic), "ProviderMark-anthropic")
        XCTAssertEqual(DockLayout.providerMarkAsset(for: .geminiVertex), "ProviderMark-geminiVertex")
        for provider in LLMProvider.allCases {
            XCTAssertEqual(DockLayout.providerMarkAsset(for: provider),
                           "ProviderMark-\(provider.rawValue)")
        }
    }

    /// The dock is controls; the user's canned prompts are content and live on the home grid.
    /// An order stored while the slot existed salvages through the same stale-identifier path as
    /// any other retired button, so no migration runs.
    func testTheQuickActionSlotIsGoneAndOldOrdersStillSalvage() {
        XCTAssertNil(DockItem(rawValue: "quickActions"))

        let order = DockLayout.effectiveOrder(
            stored: ["micMode", "quickActions", "camera"])
        XCTAssertEqual(Array(order.prefix(2)), [.micMode, .camera])
        XCTAssertEqual(order.count, DockItem.allCases.count)
    }

    /// The model tile shows a provider glyph, not the model name — every provider must map to a
    /// real symbol and distinct providers users switch between must be distinguishable.
    func testModelTileGlyphCoversAllProviders() {
        for provider in LLMProvider.allCases {
            XCTAssertFalse(DockLayout.modelTileGlyph(for: provider).isEmpty, "\(provider) has no glyph")
        }
        XCTAssertNotEqual(DockLayout.modelTileGlyph(for: .anthropic), DockLayout.modelTileGlyph(for: .chatgpt))
        XCTAssertNotEqual(DockLayout.modelTileGlyph(for: .local), DockLayout.modelTileGlyph(for: .appleOnDevice))
        XCTAssertEqual(DockLayout.modelTileGlyph(for: .openai), DockLayout.modelTileGlyph(for: .chatgpt))
    }
}
