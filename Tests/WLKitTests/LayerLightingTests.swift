import Testing
@testable import WLKit

struct LayerLightingTests {
    @Test func leavingPaintedLayerRequestsOneClear() {
        var state = LayerLightingState()
        #expect(state.observe(2, managedLayer: 2) == nil)
        state.markPainting(managedLayer: 2)
        let token = state.observe(1, managedLayer: 2)
        #expect(token != nil)
        #expect(state.mayClear(token!, managedLayer: 2))
        #expect(state.observe(1, managedLayer: 2) == nil)
    }

    @Test func initialNativeLayerAndUnpaintedDepartureAreUntouched() {
        var state = LayerLightingState()
        #expect(state.observe(1, managedLayer: 2) == nil)
        #expect(state.observe(2, managedLayer: 2) == nil)
        #expect(state.observe(1, managedLayer: 2) == nil)
    }

    @Test func nonManagedLayerChangesCannotClaimLighting() {
        var state = LayerLightingState()
        _ = state.observe(1, managedLayer: 2)
        state.markPainting(managedLayer: 2)
        #expect(state.observe(3, managedLayer: 2) == nil)
        #expect(!state.mayPaint(state.generation, managedLayer: 2))
    }

    @Test func reentryInvalidatesPendingClear() {
        var state = LayerLightingState()
        _ = state.observe(2, managedLayer: 2)
        state.markPainting(managedLayer: 2)
        let token = state.observe(1, managedLayer: 2)!
        _ = state.observe(2, managedLayer: 2)
        #expect(!state.mayClear(token, managedLayer: 2))
        #expect(state.mayPaint(state.generation, managedLayer: 2))
    }

    @Test func departureInvalidatesPendingAmbientPaint() {
        var state = LayerLightingState()
        _ = state.observe(2, managedLayer: 2)
        let paint = state.generation
        state.markPainting(managedLayer: 2)
        _ = state.observe(1, managedLayer: 2)
        #expect(!state.mayPaint(paint, managedLayer: 2))
    }

    @Test func rapidRoundTripDoesNotReviveOldClear() {
        var state = LayerLightingState()
        _ = state.observe(2, managedLayer: 2)
        state.markPainting(managedLayer: 2)
        let oldClear = state.observe(1, managedLayer: 2)!
        _ = state.observe(2, managedLayer: 2)
        state.markPainting(managedLayer: 2)
        let newClear = state.observe(1, managedLayer: 2)!
        #expect(!state.mayClear(oldClear, managedLayer: 2))
        #expect(state.mayClear(newClear, managedLayer: 2))
    }

    @Test func disconnectOrSleepInvalidatesWritesAndOwnership() {
        var state = LayerLightingState()
        _ = state.observe(2, managedLayer: 2)
        state.markPainting(managedLayer: 2)
        let paint = state.generation
        let clear = state.observe(1, managedLayer: 2)!
        state.reset()
        #expect(!state.mayPaint(paint, managedLayer: 2))
        #expect(!state.mayClear(clear, managedLayer: 2))
        #expect(state.observe(1, managedLayer: 2) == nil)
    }

    @Test func unknownLayerNeverAuthorizesClear() {
        var state = LayerLightingState()
        _ = state.observe(2, managedLayer: 2)
        state.markPainting(managedLayer: 2)
        #expect(state.observe(nil, managedLayer: 2) == nil)
        #expect(!state.mayClear(state.generation, managedLayer: 2))
        #expect(state.observe(1, managedLayer: 2) == nil)
    }

    @Test func sameLayerPollingDoesNotInvalidateInFlightPaint() {
        var state = LayerLightingState()
        _ = state.observe(2, managedLayer: 2)
        let token = state.generation
        _ = state.observe(2, managedLayer: 2)
        #expect(state.mayPaint(token, managedLayer: 2))
    }

    @Test func configuredManagedLayerIsRespected() {
        var state = LayerLightingState()
        _ = state.observe(3, managedLayer: 3)
        state.markPainting(managedLayer: 3)
        let token = state.observe(1, managedLayer: 3)!
        #expect(state.mayClear(token, managedLayer: 3))
    }
}
