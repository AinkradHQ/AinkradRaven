import Testing
import Foundation
@testable import RavenFeature

@Suite("Surface transparency")
@MainActor struct RavenAppearanceTests {

    // MARK: The legibility floor

    @Test("The opacity slider cannot reach a value that makes mail unreadable")
    func floorIsEnforced() {
        // The whole point of the clamp: whatever gets stored — a hand-edited
        // document, a future slider with a wider range, a decode of an older
        // schema — the value the views use never goes below the floor.
        #expect(RavenAppearance(rawSurfaceOpacity: 0).surfaceOpacity
                == RavenAppearance.legibleRange.lowerBound)
        #expect(RavenAppearance(rawSurfaceOpacity: -5).surfaceOpacity
                == RavenAppearance.legibleRange.lowerBound)
        #expect(RavenAppearance(rawSurfaceOpacity: 0.1).surfaceOpacity
                == RavenAppearance.legibleRange.lowerBound)
    }

    @Test("Fully opaque stays reachable, and nothing exceeds it")
    func ceilingIsEnforced() {
        #expect(RavenAppearance(rawSurfaceOpacity: 1).surfaceOpacity == 1)
        #expect(RavenAppearance(rawSurfaceOpacity: 4).surfaceOpacity == 1)
    }

    @Test("The default is translucent but not at the extreme of the range")
    func defaultLooksRightOutOfTheBox() {
        let value = RavenAppearance.default.surfaceOpacity
        // Not opaque — otherwise the fix does not happen without the user
        // finding the setting, which is the bug being fixed.
        #expect(value < 1)
        // And not the most transparent it could be: "defaulted so it looks
        // right out of the box rather than fully transparent".
        #expect(value > RavenAppearance.legibleRange.lowerBound)
    }

    // MARK: Contrast compensation

    @Test("At full opacity the text treatment is the original one and nothing stacks")
    func opaqueIsVisuallyUnchanged() {
        let opaque = RavenAppearance(rawSurfaceOpacity: 1)
        #expect(opaque.transparency == 0)
        #expect(opaque.bodyTextOpacity == 0.90)
        #expect(opaque.secondaryTextOpacity == 0.55)
        // No halo on an opaque panel — it would read as a print artifact.
        #expect(opaque.textHaloOpacity == 0)
        // An opaque pane leaves a card nothing to add: the pane is already 1,
        // so any further fill is wasted paint. The card is still distinguished
        // — by its chamfer and its border, which is where the distinction now
        // lives at every setting.
        #expect(opaque.cardFillOpacity(isRead: true) == 0)
        #expect(opaque.cardFillOpacity(isRead: false) == 0)
        #expect(opaque.cardTargetOpacity(isRead: false) == 1)
        // The modal likewise: the pane's opacity already exceeds the scrim's
        // and reaches the cap.
        #expect(opaque.modalTargetOpacity == 1)
        #expect(opaque.modalFillOpacity == 1)
    }

    // MARK: The composite law

    @Test("Two translucent layers composite by 1-(1-a)(1-b)")
    func compositeIsAlphaCompositing() {
        #expect(RavenAppearance.composite(0, 0) == 0)
        #expect(RavenAppearance.composite(1, 0) == 1)
        #expect(RavenAppearance.composite(0, 1) == 1)
        #expect(abs(RavenAppearance.composite(0.5, 0.5) - 0.75) < 1e-12)
        // The old default's actual total, which is why the pane read as a slab:
        // 0.72 pane + a 0.45·0.72 (= 0.324) card fill was effectively 0.81072
        // opaque, i.e. the user's "72% transparent-ish" was really 81% solid
        // wherever a message sat, and the blur behind it had ~19% to show
        // through. That is the slab in the screenshot.
        #expect(abs(RavenAppearance.composite(0.72, 0.45 * 0.72) - 0.81072) < 1e-9)
        // Out-of-range inputs are clamped rather than producing an opacity
        // outside 0...1.
        #expect(RavenAppearance.composite(-1, 0.5) == 0.5)
        #expect(RavenAppearance.composite(2, 0.5) == 1)
    }

    @Test("layer(over:toReach:) is the exact inverse of composite")
    func layerInvertsComposite() {
        for base in [0.0, 0.3, 0.45, 0.62, 0.9] {
            for target in [0.35, 0.5, 0.7, 0.95, 1.0] where target >= base {
                let fill = RavenAppearance.layer(over: base, toReach: target)
                #expect(abs(RavenAppearance.composite(base, fill) - target) < 1e-12)
            }
        }
        // A layer cannot subtract opacity, and nothing can be added to opaque.
        #expect(RavenAppearance.layer(over: 0.8, toReach: 0.5) == 0)
        #expect(RavenAppearance.layer(over: 1, toReach: 1) == 0)
    }

    @Test("A card's fill is derived so pane+card lands on the user's setting plus one lift")
    func cardCompositeHitsItsTarget() {
        for raw in [0.30, 0.42, 0.6, 0.8, 0.95, 1.0] {
            let appearance = RavenAppearance(rawSurfaceOpacity: raw)
            for isRead in [true, false] {
                let total = RavenAppearance.composite(
                    appearance.surfaceOpacity, appearance.cardFillOpacity(isRead: isRead))
                #expect(abs(total - appearance.cardTargetOpacity(isRead: isRead)) < 1e-12)
                // And that target is the setting plus a small absolute lift,
                // never the product of two independently chosen numbers.
                #expect(total <= min(1, appearance.surfaceOpacity
                                     + appearance.cardLift(isRead: isRead)) + 1e-12)
                #expect(total >= appearance.surfaceOpacity - 1e-12)
            }
        }
    }

    @Test("The compose modal's fill is computed over the scrim, not over nothing")
    func modalCompositeAccountsForTheScrim() {
        for raw in [0.30, 0.42, 0.6, 0.8, 1.0] {
            let appearance = RavenAppearance(rawSurfaceOpacity: raw)
            let total = RavenAppearance.composite(RavenAppearance.scrimOpacity,
                                                  appearance.modalFillOpacity)
            // Either it reaches the target exactly, or the scrim alone already
            // exceeds it and the panel paints nothing.
            #expect(total >= appearance.modalTargetOpacity - 1e-12)
            if appearance.modalTargetOpacity > RavenAppearance.scrimOpacity {
                #expect(abs(total - appearance.modalTargetOpacity) < 1e-12)
            } else {
                #expect(appearance.modalFillOpacity == 0)
            }
        }
        // At the default the panel is a few percent of theme background, not
        // the kit's hardcoded 0.94 — that difference IS the "messed up" overlay.
        #expect(RavenAppearance.default.modalFillOpacity < 0.2)
    }

    @Test("Text compensation strengthens as the surface thins out")
    func textGetsMoreLegibleAsTransparencyRises() {
        let clearest = RavenAppearance(rawSurfaceOpacity: RavenAppearance.legibleRange.lowerBound)
        let opaque = RavenAppearance(rawSurfaceOpacity: 1)
        #expect(clearest.transparency == 1)
        // Body and secondary text both rise toward full, and the halo appears.
        #expect(clearest.bodyTextOpacity > opaque.bodyTextOpacity)
        #expect(clearest.secondaryTextOpacity > opaque.secondaryTextOpacity)
        #expect(clearest.textHaloOpacity > 0)
        // Still valid opacities — a compensation that overshoots past 1 would
        // be a silently clipped value rather than an obvious bug.
        #expect(clearest.bodyTextOpacity <= 1)
        #expect(clearest.secondaryTextOpacity <= 1)
        #expect(clearest.textHaloOpacity <= 1)
    }

    @Test("A card never composites to more than a hair above the pane holding it")
    func cardsFollowTheSurface() {
        // The specific symptom in the screenshot: the pane went to glass and
        // the message cards stayed opaque slabs on top of it. The bound is on
        // the COMPOSITE, which is the thing the eye sees.
        for raw in [0.30, 0.42, 0.6, 0.85, 1.0] {
            let appearance = RavenAppearance(rawSurfaceOpacity: raw)
            for isRead in [true, false] {
                let total = RavenAppearance.composite(
                    appearance.surfaceOpacity, appearance.cardFillOpacity(isRead: isRead))
                #expect(total <= appearance.surfaceOpacity
                        + RavenAppearance.unreadCardLift + 1e-12)
            }
            // Unread still reads as heavier than read wherever there is room
            // left to be heavier in.
            if appearance.surfaceOpacity < 1 {
                #expect(appearance.cardFillOpacity(isRead: false)
                        > appearance.cardFillOpacity(isRead: true))
                #expect(appearance.cardBorderOpacity(isRead: false)
                        > appearance.cardBorderOpacity(isRead: true))
            }
        }
    }

    @Test("The default reads as glass, and the floor is the halo-backed 0.30")
    func defaultAndFloorAreTheNewOnes() {
        // Pinned as values, not just as relations: these two numbers are the
        // whole user-visible fix, and a silent drift back toward 0.72 is
        // exactly the regression to catch.
        #expect(RavenAppearance.legibleRange.lowerBound == 0.30)
        #expect(RavenAppearance.defaultSurfaceOpacity == 0.42)
        // Substantially more transparent than the old default that shipped as
        // an opaque slab.
        #expect(RavenAppearance.defaultSurfaceOpacity < 0.72)
        // The halo the lower floor leans on is genuinely engaged at the default
        // — the floor is only defensible because this is non-trivial there.
        #expect(RavenAppearance.default.textHaloOpacity > 0.4)
        #expect(RavenAppearance.default.bodyTextOpacity > 0.95)
    }

    // MARK: Persistence

    @Test("The setting survives a relaunch, and a missing document means the default")
    func persistsThroughDocuments() {
        let documents = InMemoryDocumentStore()
        // Nothing stored yet.
        let fresh = RavenAppearanceStore(documents: documents)
        #expect(fresh.appearance == .default)

        fresh.appearance = RavenAppearance(rawSurfaceOpacity: 0.55)
        // A second store over the SAME documents is the relaunch.
        let reloaded = RavenAppearanceStore(documents: documents)
        #expect(reloaded.appearance.surfaceOpacity == 0.55)
    }

    @Test("A corrupt appearance document falls back to the default rather than throwing")
    func corruptDocumentIsSurvivable() {
        let documents = InMemoryDocumentStore()
        documents.setData(Data("not json".utf8), forKey: DocumentKeys.appearance)
        #expect(RavenAppearanceStore(documents: documents).appearance == .default)
    }

    @Test("A document from before the blur setting was removed still decodes")
    func migratesFromADocumentCarryingBlur() throws {
        // The shape actually on disk for the connected account: the opacity
        // plus a now-unknown `blur` key. Decoding must keep the opacity and
        // ignore the key rather than throw and silently reset the user.
        let legacy = Data(#"{"rawSurfaceOpacity":0.55,"blur":"deep"}"#.utf8)
        let decoded = try JSONDecoder().decode(RavenAppearance.self, from: legacy)
        #expect(decoded.surfaceOpacity == 0.55)

        // Through the store, which is the path a relaunch takes.
        let documents = InMemoryDocumentStore()
        documents.setData(legacy, forKey: DocumentKeys.appearance)
        #expect(RavenAppearanceStore(documents: documents).appearance.surfaceOpacity == 0.55)
    }

    @Test("A document missing the opacity decodes to the default rather than throwing")
    func migratesFromADocumentMissingTheOpacity() throws {
        let sparse = Data(#"{"blur":"panel"}"#.utf8)
        let decoded = try JSONDecoder().decode(RavenAppearance.self, from: sparse)
        #expect(decoded == .default)
    }

    @Test("The current shape still round-trips")
    func roundTripsThroughJSON() throws {
        let original = RavenAppearance(rawSurfaceOpacity: 0.8)
        let decoded = try JSONDecoder().decode(
            RavenAppearance.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

/// Rune's rule: the title bar fill IS the surface fill, one expression, no
/// compensation. `headerFillOpacity` and `headerMaterialCompensation` are gone
/// along with the material lift they corrected for, so the only thing left to
/// assert is the identity itself.
@Suite("The header fill is the surface fill")
struct RavenHeaderFillTests {
    @Test("chromeFill's alpha equals the alpha a surface paints, at every setting")
    func headerAlphaEqualsBodyAlpha() {
        for raw in [0.0, 0.30, 0.42, 0.6, 0.9, 1.0, 4.0] {
            let appearance = RavenAppearance(rawSurfaceOpacity: raw)
            // `RavenApp.chromeFill` is `background.opacity(surfaceOpacity)` and
            // `RavenSurface` paints `background.opacity(surfaceOpacity)`. The
            // alpha the host puts in the title bar is therefore the clamped
            // setting, unscaled — no second number can drift from the first.
            #expect(appearance.surfaceOpacity
                    == min(max(raw, RavenAppearance.legibleRange.lowerBound),
                           RavenAppearance.legibleRange.upperBound))
        }
    }

    @Test("A sub-opaque setting stays sub-opaque, which is what turns the host backdrop on")
    func translucentSettingStaysTranslucent() {
        // `BlockView.isTranslucentPane` / `TileLayoutView.hasTranslucentPane`
        // test `alphaComponent < 1`, so this is the gate on the shared blurred
        // sky+island backdrop Raven now relies on instead of its own blur.
        #expect(RavenAppearance.default.surfaceOpacity < 1)
        #expect(RavenAppearance(rawSurfaceOpacity: 1).surfaceOpacity == 1)
    }
}
