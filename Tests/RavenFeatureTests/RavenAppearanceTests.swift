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
        #expect(RavenAppearance.default.blur == .panel)
    }

    // MARK: Contrast compensation

    @Test("At full opacity every derived value equals the old hardcoded one")
    func opaqueIsVisuallyUnchanged() {
        // This is the no-regression test: a user who drags the slider to 1
        // must get exactly the Raven that shipped before, not an approximation
        // of it.
        let opaque = RavenAppearance(rawSurfaceOpacity: 1)
        #expect(opaque.transparency == 0)
        #expect(opaque.bodyTextOpacity == 0.90)
        #expect(opaque.secondaryTextOpacity == 0.55)
        // No halo on an opaque panel — it would read as a print artifact.
        #expect(opaque.textHaloOpacity == 0)
        #expect(opaque.cardOpacity(isRead: true) == 0.28)
        #expect(opaque.cardOpacity(isRead: false) == 0.45)
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

    @Test("A card is never more solid than the pane holding it")
    func cardsFollowTheSurface() {
        // The specific symptom in the screenshot: the pane went to glass and
        // the message cards stayed opaque slabs on top of it.
        for raw in [0.45, 0.6, 0.72, 0.85, 1.0] {
            let appearance = RavenAppearance(rawSurfaceOpacity: raw)
            #expect(appearance.cardOpacity(isRead: true) <= appearance.surfaceOpacity)
            #expect(appearance.cardOpacity(isRead: false) <= appearance.surfaceOpacity)
            // Unread still reads as heavier than read at every setting.
            #expect(appearance.cardOpacity(isRead: false)
                    > appearance.cardOpacity(isRead: true))
        }
    }

    // MARK: Persistence

    @Test("The setting survives a relaunch, and a missing document means the default")
    func persistsThroughDocuments() {
        let documents = InMemoryDocumentStore()
        // Nothing stored yet.
        let fresh = RavenAppearanceStore(documents: documents)
        #expect(fresh.appearance == .default)

        fresh.appearance = RavenAppearance(rawSurfaceOpacity: 0.55, blur: .deep)
        // A second store over the SAME documents is the relaunch.
        let reloaded = RavenAppearanceStore(documents: documents)
        #expect(reloaded.appearance.surfaceOpacity == 0.55)
        #expect(reloaded.appearance.blur == .deep)
    }

    @Test("A corrupt appearance document falls back to the default rather than throwing")
    func corruptDocumentIsSurvivable() {
        let documents = InMemoryDocumentStore()
        documents.setData(Data("not json".utf8), forKey: DocumentKeys.appearance)
        #expect(RavenAppearanceStore(documents: documents).appearance == .default)
    }

    @Test("Blur choices round-trip through their stored raw values")
    func blurIsCodable() throws {
        for blur in RavenAppearance.Blur.allCases {
            let original = RavenAppearance(rawSurfaceOpacity: 0.8, blur: blur)
            let decoded = try JSONDecoder().decode(
                RavenAppearance.self, from: try JSONEncoder().encode(original))
            #expect(decoded == original)
            #expect(RavenAppearance.Blur(rawValue: blur.rawValue) == blur)
        }
    }
}
