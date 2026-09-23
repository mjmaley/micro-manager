/// Tracks ownership of the pad's global (not per-layer) lighting surface.
/// A departure can clear only once, and only after we actually attempted a
/// paint on our layer. Generation tokens invalidate writes across transitions.
struct LayerLightingState {
    private(set) var layer: Int?
    private(set) var generation: UInt64 = 0
    private var paintedManagedLayer = false

    /// Returns a token for a one-shot departure clear, if one is needed.
    mutating func observe(_ next: Int?, managedLayer: Int) -> UInt64? {
        guard next != layer else { return nil }
        let leaving = layer == managedLayer && next != managedLayer
        let shouldClear = leaving && next != nil && paintedManagedLayer
        layer = next
        generation &+= 1
        if leaving { paintedManagedLayer = false }
        return shouldClear ? generation : nil
    }

    mutating func markPainting(managedLayer: Int) {
        if layer == managedLayer { paintedManagedLayer = true }
    }

    func mayPaint(_ token: UInt64, managedLayer: Int) -> Bool {
        generation == token && layer == managedLayer
    }

    func mayClear(_ token: UInt64, managedLayer: Int) -> Bool {
        generation == token && layer != nil && layer != managedLayer
    }

    mutating func reset() {
        layer = nil
        generation &+= 1
        paintedManagedLayer = false
    }
}
