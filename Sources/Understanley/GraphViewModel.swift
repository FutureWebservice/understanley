import AppKit
import Foundation
import SwiftUI

/// Which geometry the canvas is showing.
enum ViewMode: String, Sendable, CaseIterable {
    /// Layered, orthogonal, calm. The working view.
    case blueprint
    /// Force-directed deep space. The overview you can feel.
    case universe

    var label: String {
        switch self {
        case .blueprint: return "Blueprint"
        case .universe: return "Universe"
        }
    }

    var other: ViewMode { self == .blueprint ? .universe : .blueprint }
}

/// Canvas state: geometry, camera, selection, and the animation clock.
///
/// Separate from `Store` because its lifetime is a graph, not a project, and
/// because everything here is redrawn at frame rate while `Store` changes a few
/// times a minute. Layout runs off the main actor and is cancelled whenever the
/// graph or the mode changes.
@MainActor
final class GraphViewModel: ObservableObject {
    // MARK: Geometry

    @Published private(set) var arrays = GraphArrays()
    @Published private(set) var blueprintIndex = SpatialIndex.empty
    @Published private(set) var universeIndex = SpatialIndex.empty
    @Published private(set) var isLayingOut = false
    @Published private(set) var layoutProgress = ""

    /// The canvas's size, owned here rather than in a view.
    ///
    /// It used to live as `@State` in two different views, set from two
    /// different `GeometryReader`s. Both were zero when the graph first loaded —
    /// a parent's `onAppear` runs before its child's — so the initial fit was
    /// computed against a made-up 1200×800 and the graph arrived off-screen or
    /// at the wrong scale. One owner, and a fit that waits for a real size.
    private(set) var viewport: CGSize = .zero
    /// Set when a layout lands; consumed by the first frame that has a viewport.
    private var needsInitialFit = false

    /// Positions for the current frame. Recomputed only while morphing;
    /// otherwise this is one of the two stored layouts with no copy at all.
    private(set) var displayPositions: [SIMD2<Float>] = []

    /// One-hop neighbourhood of the selection, cached.
    ///
    /// The renderer needs it for every node and every edge on every frame.
    /// Rebuilding the set each frame allocated thousands of times a second for
    /// data that changes only when the selection does.
    private(set) var selectionNeighbourhood: Set<Int32>?
    private(set) var focusNeighbourhood: Set<Int32>?

    // MARK: Filters
    //
    /// Categories currently shown. Empty means "no filter", not "show nothing",
    /// so the default costs nothing to evaluate and cannot hide the whole graph
    /// by accident.
    @Published private(set) var hiddenCategories: Set<NodeCategory> = []
    /// Node indices hidden by the category filter, or nil when nothing is
    /// filtered. Cached because the draw loop consults it per node per frame.
    private(set) var filteredOut: Set<Int32>?

    // MARK: Path finder
    //
    /// The node a path is being measured from, while the user picks the second.
    @Published private(set) var pathAnchor: Int?
    @Published private(set) var pathMessage: String?
    private(set) var pathNodes: Set<Int32> = []

    // MARK: Guided tour
    //
    /// Index of the step being shown, or nil when the tour is not running.
    @Published private(set) var tourStep: Int?
    /// Every node the current step is about. The canvas dims the rest, so a
    /// step reads as "here is the part of the graph this paragraph describes"
    /// rather than as a paragraph next to an unchanged picture.
    @Published private(set) var tourNodes: Set<Int32> = []
    /// Consecutive pairs of the found route, keyed for O(1) edge lookup.
    private(set) var pathEdgeKeys: Set<Int64> = []

    /// Changed nodes and their blast radius. Empty until a diff is loaded.
    @Published private(set) var diff = DiffOverlay.empty
    /// Whether the diff is being shown. Auto-enabled when a diff first arrives,
    /// because a user who has uncommitted work almost always wants to see it.
    @Published var diffMode = false

    // MARK: View state

    @Published var mode: ViewMode = .blueprint {
        didSet { guard oldValue != mode else { return }; beginMorph(to: mode) }
    }
    @Published var camera = Camera()
    @Published private(set) var selected: Int?
    @Published private(set) var hovered: Int?
    @Published private(set) var focused: Int?
    /// Node indices matching the current search, best first.
    @Published private(set) var searchHits: [Int] = []
    @Published private(set) var searchScores: [Int: Double] = [:]
    /// The route the path finder found, if any.
    @Published private(set) var pathHighlight: [Int] = []

    // MARK: Animation

    /// 0 → fully Blueprint, 1 → fully Universe.
    @Published private(set) var morph: Double = 0
    private var morphStart: Date?
    private var morphFrom: Double = 0
    private var morphTo: Double = 0
    private let morphDuration: TimeInterval = 0.9

    private var cameraTarget: Camera?
    private var cameraStart: Date?
    private let cameraDuration: TimeInterval = 0.9
    private var cameraFrom = Camera()

    private var momentum = PanMomentum()

    /// Scroll accumulated since the last frame, applied in `tick`.
    private var pendingScroll: CGSize = .zero
    /// True while scroll input is arriving, so frames keep being requested even
    /// in Blueprint where the canvas is otherwise idle.
    private var scrollIsActive = false

    /// True when something on screen is still changing. Drives whether the
    /// canvas asks for another frame — an idle Blueprint view costs nothing.
    var needsContinuousRedraw: Bool {
        mode == .universe || morphStart != nil || cameraStart != nil
            || momentum.isMoving || scrollIsActive
    }

    /// Honoured throughout: no breathing, no edge pulses, no morph.
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var layoutTask: Task<Void, Never>?
    private var graphID: String?
    /// So the auto-enable happens once per graph, not on every refresh.
    private var hasSeenDiff = false

    // MARK: - Loading

    /// Reports the canvas size. Also performs the deferred initial fit, which
    /// is the first moment a correct one is possible.
    func setViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let previous = viewport
        viewport = size
        if needsInitialFit {
            needsInitialFit = false
            fitAll(animated: false)
        } else if previous == .zero {
            fitAll(animated: false)
        }
    }

    func load(_ graph: KnowledgeGraph, entryPoint: String?) {
        let identity = graph.project.gitCommitHash + ":" + String(graph.nodes.count)
        guard identity != graphID else { return }
        graphID = identity

        layoutTask?.cancel()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        var compiled = GraphArrays.compile(graph, entryPoint: entryPoint)
        arrays = compiled
        displayPositions = compiled.blueprint
        selected = nil
        hovered = nil
        focused = nil
        searchHits = []
        pathHighlight = []
        selectionNeighbourhood = nil
        focusNeighbourhood = nil
        pathNodes = []
        pathEdgeKeys = []
        diff = .empty
        diffMode = false
        hasSeenDiff = false
        isLayingOut = true
        layoutProgress = "Laying out \(compiled.count) nodes…"

        layoutTask = Task { [weak self] in
            // Both geometries are computed up front. It costs one extra pass at
            // load and buys an instant, morphable mode switch — the transition
            // is the moment the app is judged on, and it cannot stutter.
            let snapshot = compiled
            let layered = await Task.detached(priority: .userInitiated) {
                LayeredLayout.compute(snapshot, isCancelled: { Task.isCancelled })
            }.value
            if Task.isCancelled { return }

            let forced = await Task.detached(priority: .userInitiated) {
                ForceLayout.compute(snapshot, isCancelled: { Task.isCancelled })
            }.value
            if Task.isCancelled { return }

            compiled.blueprint = layered.positions
            compiled.universe = forced

            let blueprintIndex = SpatialIndex(positions: layered.positions)
            let universeIndex = SpatialIndex(positions: forced)

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.arrays = compiled
                self.blueprintIndex = blueprintIndex
                self.universeIndex = universeIndex
                self.isLayingOut = false
                self.layoutProgress = ""
                self.refreshDisplayPositions()
                // Fit now if the canvas has reported its size; otherwise the
                // next `setViewport` does it. Fitting against a zero or
                // guessed size is what put the graph off-screen before.
                if self.viewport == .zero {
                    self.needsInitialFit = true
                } else {
                    self.fitAll(animated: false)
                }
            }
        }
    }

    func cancel() {
        layoutTask?.cancel()
        layoutTask = nil
    }

    // MARK: - Positions

    /// Node positions for the current morph state.
    ///
    /// Mid-transition this is a per-node blend of the two layouts, staggered by
    /// layer so constellations peel away in sequence rather than all at once.
    func position(_ index: Int) -> SIMD2<Float> {
        guard index < arrays.count else { return .zero }
        let a = arrays.blueprint[index]
        let b = arrays.universe[index]
        if morph <= 0 { return a }
        if morph >= 1 { return b }

        let layer = arrays.layerIndex[index]
        let layerCount = max(1, arrays.layerNames.count)
        let stagger = layer >= 0 ? Double(layer) / Double(layerCount) * 0.35 : 0
        let local = min(1, max(0, (morph - stagger) / (1 - 0.35)))
        let eased = Camera.easeInOut(local)
        return a + (b - a) * Float(eased)
    }

    /// Rebuilds `displayPositions` for the current morph value.
    ///
    /// Called from `tick` only while a morph is running. At rest this assigns
    /// one of the stored layouts, so a settled canvas copies nothing.
    private func refreshDisplayPositions() {
        if morph <= 0 {
            displayPositions = arrays.blueprint
        } else if morph >= 1 {
            displayPositions = arrays.universe
        } else {
            displayPositions = (0..<arrays.count).map { position($0) }
        }
    }

    private var activeIndex: SpatialIndex {
        morph >= 0.5 ? universeIndex : blueprintIndex
    }

    // MARK: - Interaction

    func hitTest(_ screen: CGPoint) -> Int? {
        guard viewport != .zero else { return nil }
        let world = camera.screenToWorld(screen, viewport: viewport)
        // Generous in world units at low zoom, so a node stays clickable when
        // it is only a few pixels across.
        let slack = Float(max(18, 26 / camera.zoom))
        return activeIndex.nearest(to: world, within: slack, positions: displayPositions)
    }

    func select(_ index: Int?) {
        selected = index
        selectionNeighbourhood = index.map { arrays.neighbourhood(of: $0) }
        if index == nil {
            pathHighlight = []
            pathNodes = []
            pathEdgeKeys = []
        }
    }

    func hover(_ index: Int?) {
        guard hovered != index else { return }
        hovered = index
    }

    func toggleFocus() {
        focused = focused == nil ? selected : nil
        focusNeighbourhood = focused.map { arrays.neighbourhood(of: $0) }
    }

    func setSearchResults(_ hits: [(index: Int, score: Double)]) {
        searchHits = hits.map(\.index)
        searchScores = Dictionary(hits.map { ($0.index, $0.score) }, uniquingKeysWith: { a, _ in a })
    }

    func clearSearch() {
        searchHits = []
        searchScores = [:]
    }

    /// Recomputes the diff overlay for a set of changed paths.
    func setChangedFiles(_ files: [String], graph: KnowledgeGraph) {
        guard !arrays.isEmpty else { return }
        let overlay = DiffOverlay.compute(changedFiles: files, arrays: arrays, graph: graph)
        diff = overlay
        if overlay.isEmpty {
            diffMode = false
        } else if !overlay.changed.isEmpty, !hasSeenDiff {
            hasSeenDiff = true
            diffMode = true
        }
    }

    func toggleDiff() {
        guard !diff.isEmpty else { return }
        diffMode.toggle()
    }

    /// Toggles a whole category of node in or out of the drawing.
    func toggleCategory(_ category: NodeCategory) {
        if hiddenCategories.contains(category) {
            hiddenCategories.remove(category)
        } else {
            hiddenCategories.insert(category)
        }
        rebuildFilter()
    }

    func clearFilters() {
        hiddenCategories = []
        rebuildFilter()
    }

    private func rebuildFilter() {
        guard !hiddenCategories.isEmpty else { filteredOut = nil; return }
        var out: Set<Int32> = []
        for index in 0..<arrays.count where hiddenCategories.contains(arrays.types[index].category) {
            out.insert(Int32(index))
        }
        filteredOut = out
    }

    /// Node counts per category, for the filter chips.
    func categoryCounts() -> [(NodeCategory, Int)] {
        var counts: [NodeCategory: Int] = [:]
        for index in 0..<arrays.count { counts[arrays.types[index].category, default: 0] += 1 }
        return NodeCategory.allCases.compactMap { category in
            counts[category].map { (category, $0) }
        }
    }

    // MARK: - Path finder

    /// Starts, completes or restarts a path measurement.
    ///
    /// Two clicks rather than a modal picker: press `p` on a node to anchor,
    /// then `p` on another to draw the route between them. `findPath` has
    /// existed since the first version and was never reachable from anywhere.
    func markPathEndpoint(_ index: Int?) {
        guard let index else { return }
        guard let anchor = pathAnchor else {
            pathAnchor = index
            pathMessage = "Path from \(arrays.names[index]) — now pick the other end."
            return
        }
        guard anchor != index else {
            pathMessage = "Pick a different node for the other end."
            return
        }
        findPath(from: anchor, to: index)
        pathAnchor = nil
        pathMessage = pathHighlight.isEmpty
            ? "No route between those two."
            : "\(pathHighlight.count) nodes: \(arrays.names[anchor]) → \(arrays.names[index])"
    }

    func clearPath() {
        pathAnchor = nil
        pathMessage = nil
        pathHighlight = []
        pathNodes = []
        pathEdgeKeys = []
    }

    func findPath(from start: Int, to end: Int) {
        pathHighlight = arrays.shortestPath(from: start, to: end)
        pathNodes = Set(pathHighlight.map(Int32.init))
        pathEdgeKeys = []
        for (a, b) in zip(pathHighlight, pathHighlight.dropFirst()) {
            pathEdgeKeys.insert(Int64(min(a, b)) << 32 | Int64(max(a, b)))
        }
    }

    // MARK: - Camera control

    func fitAll(animated: Bool = true) {
        guard viewport != .zero else {
            needsInitialFit = true
            return
        }
        let rect = GraphArrays.bounds(of: displayPositions)
        guard rect.width > 0 else { return }
        move(to: Camera.fitting(rect, viewport: viewport), animated: animated)
    }

    /// Shows one step of the tour: highlights its nodes and flies to them.
    func playTour(_ steps: [TourStep], step: Int) {
        guard !steps.isEmpty else { return }
        let clamped = ((step % steps.count) + steps.count) % steps.count
        tourStep = clamped

        let indices = steps[clamped].nodeIds.compactMap { arrays.index(of: $0) }
        tourNodes = Set(indices.map(Int32.init))
        if let first = indices.first { selected = first }
        selectionNeighbourhood = nil
        frameCamera(on: indices)
    }

    func stopTour() {
        tourStep = nil
        tourNodes = []
    }

    /// Frames a group of nodes together, so a whole step is visible at once.
    func frameCamera(on indices: [Int]) {
        guard viewport != .zero, !indices.isEmpty else { return }
        let points = indices.compactMap { $0 < displayPositions.count ? displayPositions[$0] : nil }
        guard !points.isEmpty else { return }
        var rect = GraphArrays.bounds(of: points)
        // A single node has almost no extent, and fitting to it slams the
        // camera in until that one card fills the window — which is
        // disorienting, because a tour step is about where something sits in
        // the project, not about the card itself. Guarantee a window several
        // cards wide so the neighbours stay visible.
        let minimumWidth: CGFloat = 2600
        let minimumHeight: CGFloat = 1700
        if rect.width < minimumWidth {
            rect = rect.insetBy(dx: -(minimumWidth - rect.width) / 2, dy: 0)
        }
        if rect.height < minimumHeight {
            rect = rect.insetBy(dx: 0, dy: -(minimumHeight - rect.height) / 2)
        }
        move(to: Camera.fitting(rect, viewport: viewport), animated: true)
    }

    /// Frames a node without changing zoom, unless the view is so far out that
    /// arriving there would show nothing.
    func focusCamera(on index: Int) {
        guard index < arrays.count, viewport != .zero else { return }
        let target = Camera(centre: position(index), zoom: max(camera.zoom, 0.75))
        move(to: target, animated: true)
    }

    func move(to target: Camera, animated: Bool) {
        momentum.stop()
        guard animated, !reduceMotion else {
            camera = target
            cameraTarget = nil
            cameraStart = nil
            return
        }
        cameraFrom = camera
        cameraTarget = target
        cameraStart = Date()
    }

    func beginDrag() {
        momentum.begin()
        cameraTarget = nil
        cameraStart = nil
    }

    func drag(by delta: CGSize) {
        camera.pan(by: delta)
        momentum.record(delta: delta, zoom: camera.zoom)
    }

    /// Queues a scroll delta to be applied on the next frame.
    ///
    /// A trackpad emits scroll events far faster than the display refreshes.
    /// Applying each one immediately mutates `@Published camera` dozens of
    /// times between frames, and every mutation invalidates the view — so the
    /// canvas is asked to redraw repeatedly for intermediate states that are
    /// never shown. Accumulating and applying once per tick decouples input
    /// rate from frame rate, which is most of what "smoother" means here.
    func queueScroll(_ delta: CGSize) {
        pendingScroll.width += delta.width
        pendingScroll.height += delta.height
        scrollIsActive = true
    }

    func endDrag() {}

    func zoom(by factor: Double, at anchor: CGPoint) {
        guard viewport != .zero else { return }
        cameraTarget = nil
        cameraStart = nil
        camera.zoom(by: factor, anchor: anchor, viewport: viewport)
    }

    // MARK: - Frame tick

    /// Advances every time-based animation. Called once per rendered frame.
    func tick(now: Date) {
        // Scroll first: applying the whole accumulated delta once per frame
        // means the camera moves exactly as far as the user scrolled, with one
        // invalidation instead of dozens.
        if pendingScroll != .zero {
            camera.pan(by: pendingScroll)
            // Deliberately no momentum here. macOS already delivers its own
            // inertia as a tail of `scrollWheel` events after the fingers lift,
            // so adding a second coast on top makes the view overshoot and
            // drift — which reads as mushy, the exact opposite of smooth.
            // Momentum belongs only to the drag gesture, where there is none.
            pendingScroll = .zero
        } else {
            scrollIsActive = false
        }

        if let start = morphStart {
            let t = min(1, now.timeIntervalSince(start) / morphDuration)
            morph = morphFrom + (morphTo - morphFrom) * Camera.easeInOut(t)
            if t >= 1 {
                morph = morphTo
                morphStart = nil
            }
            refreshDisplayPositions()
        }

        if let start = cameraStart, let target = cameraTarget {
            let t = min(1, now.timeIntervalSince(start) / cameraDuration)
            camera = cameraFrom.interpolated(toward: target, t: t)
            if t >= 1 {
                camera = target
                cameraStart = nil
                cameraTarget = nil
            }
        } else if let push = momentum.step() {
            camera.centre += push
        }
    }

    private func beginMorph(to newMode: ViewMode) {
        let destination: Double = newMode == .universe ? 1 : 0

        // Refit onto the layout being arrived at, not the one being left.
        // The two have very different extents — Blueprint spreads into a wide
        // grid, Universe pulls into a compact cloud — so carrying the old
        // camera across strands the new view in a corner of an otherwise empty
        // canvas. On a small project that read as "Universe is broken"; the
        // layout was fine all along, the framing was not.
        let arriving = newMode == .universe ? arrays.universe : arrays.blueprint
        if viewport != .zero, !arriving.isEmpty {
            let rect = GraphArrays.bounds(of: arriving)
            if rect.width > 0 {
                move(to: Camera.fitting(rect, viewport: viewport), animated: !reduceMotion)
            }
        }
        guard !reduceMotion else {
            morph = destination
            morphStart = nil
            return
        }
        morphFrom = morph
        morphTo = destination
        morphStart = Date()
    }
}
