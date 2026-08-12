import SwiftUI

/// The graph, drawn.
///
/// One `Canvas` serves both visual modes. It is immediate-mode and
/// GPU-composited, which is what lets thousands of nodes coexist — SwiftUI
/// cannot hold that many `View`s, and React Flow only avoids the same wall by
/// collapsing most of the graph behind containers.
///
/// The frame budget is spent very deliberately. At 1 500 nodes and 3 200 edges
/// a naive draw loop allocates tens of thousands of times per frame — a `Path`
/// per star, a `Gradient` per edge, a `Set` per node — and no amount of GPU
/// makes that smooth. Almost everything below is batched, cached or culled for
/// that reason.
struct GraphCanvas: View {
    @ObservedObject var model: GraphViewModel

    @State private var dragOrigin: CGPoint?
    @State private var lastDrag: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            // 60 fps rather than 120. On a ProMotion display the scheduler will
            // happily ask for twice the frames, which doubles the work for a
            // difference nobody can see on a graph that is mostly static.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                    paused: !model.needsContinuousRedraw)) { timeline in
                Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                    model.tick(now: timeline.date)
                    draw(context: &context, size: size, now: timeline.date)
                }
                // No `.drawingGroup()`: `Canvas` already composites through
                // Metal, and wrapping it forces an extra full-surface offscreen
                // copy every single frame.
            }
            .background(background)
            .contentShape(Rectangle())
            .onAppear { model.setViewport(geometry.size) }
            .onChange(of: geometry.size) { model.setViewport($0) }
            .gesture(dragGesture)
            .onCanvasScroll(
                scroll: { delta, _ in model.queueScroll(delta) },
                zoom: { factor, anchor in model.zoom(by: factor, at: anchor) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): model.hover(model.hitTest(point))
                case .ended: model.hover(nil)
                }
            }
            .overlay(alignment: .topLeading) { overlay }
        }
    }

    // MARK: - Chrome

    private var background: some View {
        LinearGradient(
            colors: model.morph > 0.02
                ? [Palette.spaceTop, Palette.spaceBottom]
                : [Theme.root, Theme.root],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    @ViewBuilder private var overlay: some View {
        if model.isLayingOut {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.layoutProgress)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(16)
        }
    }

    /// Pan and click, in one gesture.
    ///
    /// A location-aware `onTapGesture` is macOS 14 only, and the deployment
    /// target is 13. Folding both into a zero-distance drag also removes a real
    /// conflict: a separate tap recogniser competes with panning and swallows
    /// the first few pixels of every drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                    lastDrag = .zero
                    model.beginDrag()
                }
                let delta = CGSize(
                    width: value.translation.width - lastDrag.width,
                    height: value.translation.height - lastDrag.height
                )
                lastDrag = value.translation
                model.drag(by: delta)
            }
            .onEnded { value in
                let travelled = abs(value.translation.width) + abs(value.translation.height)
                if travelled < 3 {
                    model.select(model.hitTest(value.startLocation))
                }
                dragOrigin = nil
                lastDrag = .zero
                model.endDrag()
            }
    }

    // MARK: - Frame

    private func draw(context: inout GraphicsContext, size: CGSize, now: Date) {
        let arrays = model.arrays
        guard !arrays.isEmpty, !model.displayPositions.isEmpty else { return }

        let camera = model.camera
        let lod = LODLevel.forZoom(camera.zoom)
        let positions = model.displayPositions
        let universeness = model.morph
        let time = now.timeIntervalSinceReferenceDate

        if universeness > 0.02 {
            drawStarfield(&context, size: size, camera: camera, alpha: universeness)
        }

        // Cached in the model, rebuilt only when the selection or focus changes.
        let restricted = model.focusNeighbourhood
        let neighbourhood = model.selectionNeighbourhood
        let pathNodes = model.pathNodes
        let diff = model.diff
        let diffActive = model.diffMode && !diff.isEmpty

        // Which nodes are on screen. Mid-morph both spatial indexes disagree
        // with actual positions, so a full pass is the honest answer — it lasts
        // under a second and only while the transition runs.
        let midMorph = universeness > 0.02 && universeness < 0.98
        let visibleRect = camera.visibleWorldRect(viewport: size)
        let candidates: [Int32] = midMorph
            ? Array(0..<Int32(arrays.count))
            : (universeness >= 0.5 ? model.universeIndex : model.blueprintIndex)
                .items(in: visibleRect)

        if lod.drawEdges {
            drawEdges(
                &context, arrays: arrays, positions: positions, camera: camera, size: size,
                lod: lod, universeness: universeness, restricted: restricted,
                neighbourhood: neighbourhood, pathNodes: pathNodes, time: time
            )
        }

        // Visible nodes, resolved once and reused by both passes below.
        var visible: [(index: Int, point: CGPoint, emphasis: Double)] = []
        visible.reserveCapacity(min(candidates.count, 2048))

        for raw in candidates {
            let index = Int(raw)
            guard index < positions.count else { continue }
            if let restricted, !restricted.contains(raw) { continue }
            if let filtered = model.filteredOut, filtered.contains(raw) { continue }

            let screen = camera.worldToScreen(positions[index], viewport: size)
            guard screen.x > -200, screen.y > -200,
                  screen.x < size.width + 200, screen.y < size.height + 200 else { continue }

            // A search hit stays lit even while a selection dims the rest.
            // Without this, searching with a node selected reports a match
            // count and highlights nothing — the same flaw the exported viewer
            // had, and equally invisible from a terminal.
            let isHit = model.searchScores[index] != nil
            var emphasis: Double = 1
            if let neighbourhood, !neighbourhood.contains(raw), !isHit {
                emphasis = 0.18
            } else if neighbourhood == nil, !model.searchScores.isEmpty, !isHit {
                // Searching has to dim the field, not just brighten the hits.
                // Nine matches among fifteen hundred bodies are invisible at a
                // 1.6× radius — the count in the toolbar says "found" and the
                // canvas looks unchanged, which reads as a broken search.
                emphasis = 0.2
            }
            if !pathNodes.isEmpty { emphasis = pathNodes.contains(raw) ? 1 : 0.1 }
            if !model.tourNodes.isEmpty { emphasis = model.tourNodes.contains(raw) ? 1 : 0.12 }
            // Diff mode is the strongest signal on screen, so it overrides the
            // others: when you are asking "what did I break", everything that
            // cannot have broken should recede.
            if diffActive {
                emphasis = (diff.changed.contains(raw) || diff.affected.contains(raw)) ? 1 : 0.14
            }
            visible.append((index, screen, emphasis))
        }

        if universeness < 0.98 {
            for entry in visible {
                drawBlueprintNode(
                    &context, arrays: arrays, index: entry.index, at: entry.point,
                    camera: camera, lod: lod, alpha: (1 - universeness) * entry.emphasis,
                    searchScore: model.searchScores[entry.index],
                    diffState: diffActive ? diffState(entry.index, diff) : nil
                )
            }
        }

        if universeness > 0.02 {
            // Halos share one additive context for the whole frame. Copying the
            // context and flipping the blend mode per node meant a graphics
            // state change per body — the same work the batching elsewhere
            // exists to avoid.
            var glow = context
            glow.blendMode = .plusLighter
            for entry in visible {
                drawHalo(&glow, arrays: arrays, index: entry.index, at: entry.point,
                         camera: camera, alpha: universeness * entry.emphasis, time: time,
                         searchScore: model.searchScores[entry.index])
            }
            if lod.drawCores {
                for entry in visible {
                    drawCore(&context, arrays: arrays, index: entry.index, at: entry.point,
                             camera: camera, alpha: universeness * entry.emphasis, time: time,
                             diffState: diffActive ? diffState(entry.index, diff) : nil)
                }
            }
        }

        // Universe only. Blueprint names are drawn inside their own card now,
        // where they belong — running both passes printed every name twice
        // through the morph.
        if lod.drawLabels, universeness > 0.5 {
            drawLabels(
                &context, arrays: arrays, positions: positions, candidates: candidates,
                camera: camera, size: size, lod: lod, universeness: universeness,
                restricted: restricted, neighbourhood: neighbourhood
            )
        }
    }

    // MARK: Starfield

    private func drawStarfield(
        _ context: inout GraphicsContext, size: CGSize, camera: Camera, alpha: Double
    ) {
        let field = Starfield.shared
        for plane in field.planes {
            // Each plane translates by a fraction of the camera, which is what
            // produces parallax. The modulo tiles it infinitely without
            // generating more stars.
            let offsetX = CGFloat(camera.centre.x * plane.parallax)
            let offsetY = CGFloat(camera.centre.y * plane.parallax)
            let tile = CGFloat(field.tileSize)
            let originX = (offsetX.truncatingRemainder(dividingBy: tile) + tile)
                .truncatingRemainder(dividingBy: tile)
            let originY = (offsetY.truncatingRemainder(dividingBy: tile) + tile)
                .truncatingRemainder(dividingBy: tile)

            let columns = floorToInt(Float(size.width / tile)) + 2
            let rows = floorToInt(Float(size.height / tile)) + 2

            // Two passes, bright and dim, each accumulated into ONE path and
            // filled once. A `Path` and a `fill` per star was several thousand
            // allocations and draw calls every frame, for the cheapest thing on
            // screen.
            var bright = Path()
            var dim = Path()

            for column in 0..<columns {
                let baseX = CGFloat(column) * tile - originX
                guard baseX < size.width + tile, baseX > -tile else { continue }
                for row in 0..<rows {
                    let baseY = CGFloat(row) * tile - originY
                    guard baseY < size.height + tile, baseY > -tile else { continue }

                    for star in plane.stars {
                        let x = baseX + CGFloat(star.position.x)
                        let y = baseY + CGFloat(star.position.y)
                        guard x > -2, y > -2, x < size.width + 2, y < size.height + 2 else {
                            continue
                        }
                        let r = CGFloat(star.radius)
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        if star.opacity > 0.35 {
                            bright.addEllipse(in: rect)
                        } else {
                            dim.addEllipse(in: rect)
                        }
                    }
                }
            }
            context.fill(bright, with: .color(.white.opacity(0.5 * alpha)))
            context.fill(dim, with: .color(.white.opacity(0.22 * alpha)))
        }
    }

    // MARK: Edges

    private func drawEdges(
        _ context: inout GraphicsContext, arrays: GraphArrays, positions: [SIMD2<Float>],
        camera: Camera, size: CGSize, lod: LODLevel, universeness: Double,
        restricted: Set<Int32>?, neighbourhood: Set<Int32>?, pathNodes: Set<Int32>,
        time: TimeInterval
    ) {
        let selected = model.selected.map(Int32.init)
        let pathKeys = model.pathEdgeKeys
        // A search dims the web too. Hits are small; they only read as found
        // if the surrounding field steps back for them.
        let dimmed = neighbourhood != nil || !pathNodes.isEmpty
            || !model.searchScores.isEmpty || !model.tourNodes.isEmpty

        // Ordinary edges are accumulated into one path per hue bucket and
        // stroked once each — 24 stroke calls instead of 3 200, and no
        // per-edge `Gradient` allocation. Only the edges a reader is actually
        // looking at get individual treatment.
        var buckets = [Path](repeating: Path(), count: GlowAtlas.hueBucketCount)
        var touched = [Bool](repeating: false, count: GlowAtlas.hueBucketCount)
        var highlights: [(Path, Int, Int, Bool)] = []

        for e in 0..<arrays.edgeCount {
            let a = Int(arrays.edgeSource[e])
            let b = Int(arrays.edgeTarget[e])
            guard a < positions.count, b < positions.count else { continue }
            if let restricted,
               !(restricted.contains(Int32(a)) && restricted.contains(Int32(b))) { continue }
            if let filtered = model.filteredOut,
               filtered.contains(Int32(a)) || filtered.contains(Int32(b)) { continue }

            let p1 = camera.worldToScreen(positions[a], viewport: size)
            let p2 = camera.worldToScreen(positions[b], viewport: size)

            // Reject before doing anything that allocates.
            if (p1.x < 0 && p2.x < 0) || (p1.y < 0 && p2.y < 0)
                || (p1.x > size.width && p2.x > size.width)
                || (p1.y > size.height && p2.y > size.height) { continue }

            let touchesSelection = selected.map { $0 == Int32(a) || $0 == Int32(b) } ?? false
            let key = Int64(min(a, b)) << 32 | Int64(max(a, b))
            let onPath = pathKeys.contains(key)

            if touchesSelection || onPath {
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                highlights.append((path, a, b, onPath))
                continue
            }
            // Everything else recedes when something is selected, so there is
            // no point paying for it at full fidelity.
            let bucket = GlowAtlas.hueBucket(arrays.hues[a])
            buckets[bucket].move(to: p1)
            buckets[bucket].addLine(to: p2)
            touched[bucket] = true
        }

        // Raised from 0.17. At the old value a Blueprint edge stroked out to
        // roughly #221C16 on a #0A0A0A background — technically drawn, not
        // actually visible, so the graph read as a grid of unconnected cards.
        let baseOpacity = dimmed ? 0.06 : 0.30
        for bucket in 0..<GlowAtlas.hueBucketCount where touched[bucket] {
            let colour: Color = universeness > 0.15
                ? Palette.color(hue: Float(GlowAtlas.hue(forBucket: bucket)),
                                brightness: 0.9, saturation: 0.5,
                                opacity: baseOpacity * universeness)
                : Theme.accent.opacity(baseOpacity * 0.7)
            context.stroke(buckets[bucket], with: .color(colour), lineWidth: 1)

            // In Blueprint the accent wash sits under the hue so the view keeps
            // its calmer, single-tone character.
            if universeness > 0.15, universeness < 0.98 {
                context.stroke(
                    buckets[bucket],
                    with: .color(Theme.accent.opacity(baseOpacity * (1 - universeness) * 0.6)),
                    lineWidth: 1
                )
            }
        }

        // Highlighted edges: full gradient, wider stroke, and a travelling
        // pulse. Few enough that the per-edge cost is irrelevant.
        for (path, a, b, onPath) in highlights {
            let width: CGFloat = onPath ? 3 : 2
            let opacity: Double = onPath ? 1 : 0.85

            if lod.drawEdgeGradients, universeness > 0.15,
               let start = path.currentPoint {
                _ = start
                let p1 = camera.worldToScreen(positions[a], viewport: size)
                let p2 = camera.worldToScreen(positions[b], viewport: size)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [
                        Palette.color(hue: arrays.hues[a], brightness: 0.95, saturation: 0.55,
                                      opacity: opacity),
                        Palette.color(hue: arrays.hues[b], brightness: 0.95, saturation: 0.55,
                                      opacity: opacity),
                    ]),
                    startPoint: p1, endPoint: p2
                )
                context.stroke(path, with: shading, lineWidth: width)
            } else {
                context.stroke(path, with: .color(Theme.accent.opacity(opacity)), lineWidth: width)
            }

            if universeness > 0.3, !model.reduceMotion {
                let p1 = camera.worldToScreen(positions[a], viewport: size)
                let p2 = camera.worldToScreen(positions[b], viewport: size)
                let t = (time * 0.55).truncatingRemainder(dividingBy: 1)
                let x = p1.x + (p2.x - p1.x) * t
                let y = p1.y + (p2.y - p1.y) * t
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)),
                    with: .color(Theme.accentBright.opacity(0.85 * universeness))
                )
            }
        }
    }

    // MARK: Blueprint node

    /// Whether a node changed, is downstream of a change, or neither.
    private enum DiffState { case changed, affected }

    private func diffState(_ index: Int, _ diff: DiffOverlay) -> DiffState? {
        let raw = Int32(index)
        if diff.changed.contains(raw) { return .changed }
        if diff.affected.contains(raw) { return .affected }
        return nil
    }

    private func drawBlueprintNode(
        _ context: inout GraphicsContext, arrays: GraphArrays, index: Int,
        at screen: CGPoint, camera: Camera, lod: LODLevel, alpha: Double,
        searchScore: Double?, diffState: DiffState? = nil
    ) {
        guard alpha > 0.01 else { return }
        let width = CGFloat(arrays.cardSize[index].x) * camera.zoom
        let height = CGFloat(arrays.cardSize[index].y) * camera.zoom
        let rect = CGRect(x: screen.x - width / 2, y: screen.y - height / 2,
                          width: width, height: height)

        // Below the point where a card is readable, draw a dot instead.
        guard lod.drawCores else {
            let r = max(1.5, 3 * camera.zoom)
            context.fill(
                Path(ellipseIn: CGRect(x: screen.x - r, y: screen.y - r, width: r * 2, height: r * 2)),
                with: .color(Theme.color(for: arrays.types[index]).opacity(alpha * 0.9))
            )
            return
        }

        let typeColour = Theme.color(for: arrays.types[index])
        // Two colours, two questions. The left bar answers "what kind of thing
        // is this" (type), the tint and border answer "which part of the system
        // does it belong to" (layer). Using the type for both left the layers —
        // the app's main organising idea, and the thing the Universe view is
        // built around — completely invisible in Blueprint.
        let layer = arrays.layerIndex[index]
        let layerColour: Color = layer >= 0 && Int(layer) < arrays.layerHues.count
            ? Palette.color(hue: arrays.layerHues[Int(layer)], brightness: 0.85, saturation: 0.55)
            : typeColour
        let isSelected = model.selected == index
        let isHovered = model.hovered == index

        // Corner radius scales with the card but stops growing, so a zoomed-in
        // card stays a card instead of turning into a lozenge.
        let radius = min(14, max(3, 10 * camera.zoom))
        let shape = Path(roundedRect: rect, cornerRadius: radius)

        // A shadow under the selection and the hover only. Doing it for every
        // card would cost a full offscreen pass per node and read as mush;
        // doing it for the one card you are pointing at is what makes the
        // surface feel like it has layers.
        if isSelected || isHovered {
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.55),
                                        radius: 10 * max(0.6, camera.zoom),
                                        y: 3 * max(0.6, camera.zoom)))
                layer.fill(shape, with: .color(Theme.elevated.opacity(alpha)))
            }
        }

        // Body: a soft vertical gradient tinted toward the node's own type
        // colour. A flat fill made every card the identical #1A1A1A rectangle,
        // so the type was carried only by a 1pt bar that vanishes when the view
        // is zoomed out — which is exactly when you most need to tell a config
        // file from a component.
        context.fill(
            shape,
            with: .linearGradient(
                Gradient(colors: [
                    Theme.elevated.opacity(alpha),
                    layerColour.opacity(alpha * (isSelected ? 0.22 : 0.13)),
                ]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )

        // Border carries the type colour too, so identity survives at any zoom.
        var ringColour = layerColour.opacity(isHovered ? 0.8 : 0.45)
        var ringWidth: CGFloat = 1
        if let diffState {
            ringColour = diffState == .changed ? Theme.diffChanged : Theme.diffAffected
            ringWidth = diffState == .changed ? 2.5 : 1.5
        } else if isSelected {
            ringColour = Theme.accentBright
            ringWidth = 2
        } else if let score = searchScore {
            ringColour = score <= 0.1 ? Theme.accentBright
                : (score <= 0.3 ? Theme.accent : Theme.accentDim.opacity(0.7))
            ringWidth = 2
        } else if isHovered {
            ringWidth = 1.5
        }
        context.stroke(shape, with: .color(ringColour.opacity(alpha)),
                       lineWidth: ringWidth * max(0.8, camera.zoom))

        // Left accent, clipped to the card so it takes the corner radius on the
        // left and stays square where it meets the body.
        let barWidth = max(2, 4.5 * camera.zoom)
        context.drawLayer { layer in
            layer.clip(to: shape)
            layer.fill(
                Path(CGRect(x: rect.minX, y: rect.minY, width: barWidth, height: rect.height)),
                with: .color(typeColour.opacity(alpha))
            )
        }

        drawCardContent(&context, arrays: arrays, index: index, in: rect, alpha: alpha)
    }

    /// The text and badges on a Blueprint card.
    ///
    /// Sized against the card's **on-screen** rectangle rather than the camera
    /// zoom. A fixed zoom gate blanked every card on any project small enough to
    /// fit the window at once: a 280pt card at zoom 0.26 is still 73pt wide —
    /// easily enough for a name — but the old `zoom > 0.55` test said no, so a
    /// 48-file project rendered as a grid of empty boxes.
    ///
    /// Each element appears only once there is genuinely room for it, so the
    /// card degrades one line at a time instead of all at once.
    private func drawCardContent(
        _ context: inout GraphicsContext, arrays: GraphArrays, index: Int,
        in rect: CGRect, alpha: Double
    ) {
        // Every decision about what fits comes from `CardLayout`, which is a
        // plain function with tests. It used to be duplicated inline here,
        // which meant the tested copy and the drawn copy could drift apart
        // without anything failing.
        let plan = CardLayout.forCard(
            width: rect.width, height: rect.height,
            hasSummary: !arrays.summaries[index].isEmpty,
            isComplex: arrays.complexity[index] != .simple,
            isTested: arrays.flags[index].contains(.tested)
        )
        guard plan.showsName else { return }

        let inset = max(3, rect.width * 0.035)
        let left = rect.minX + inset + rect.width * 0.02
        let nameSize = plan.nameSize
        let typeSize = nameSize * 0.68
        let showsType = plan.showsType
        let summary = arrays.summaries[index]
        let showsSummary = plan.showsSummary

        if plan.showsTestedDot {
            let r = max(1.5, rect.width * 0.012)
            context.fill(
                Path(ellipseIn: CGRect(x: rect.maxX - inset - r * 2, y: rect.minY + inset,
                                       width: r * 2, height: r * 2)),
                with: .color(Theme.tested.opacity(alpha))
            )
        }

        var y = (showsType || showsSummary)
            ? rect.minY + inset + (showsType ? typeSize * 0.9 : nameSize * 0.2)
            : rect.midY

        if showsType {
            context.draw(
                Text(arrays.types[index].rawValue.uppercased())
                    .font(.system(size: typeSize, weight: .semibold))
                    .foregroundColor(Theme.color(for: arrays.types[index]).opacity(alpha * 0.85)),
                at: CGPoint(x: left, y: y), anchor: .leading
            )
            // The complexity chip rides the type line, right-aligned, and only
            // when it will not collide with the type label.
            if plan.showsComplexityChip {
                let colour = arrays.complexity[index] == .complex
                    ? Theme.diffChanged : Theme.diffAffected
                let chipWidth = max(5, rect.width * 0.035)
                let chipHeight = max(3, typeSize * 0.5)
                let chip = CGRect(x: rect.maxX - inset - chipWidth - rect.width * 0.05,
                                  y: y - chipHeight / 2, width: chipWidth, height: chipHeight)
                context.fill(Path(roundedRect: chip, cornerRadius: chipHeight / 2),
                             with: .color(colour.opacity(alpha * 0.8)))
            }
            y += typeSize * 1.45
        }

        context.draw(
            Text(fit(arrays.names[index], budget: plan.nameBudget))
                .font(.system(size: nameSize, weight: .medium))
                .foregroundColor(Theme.textPrimary.opacity(alpha)),
            at: CGPoint(x: left, y: y), anchor: .leading
        )

        guard showsSummary else { return }
        let summarySize = nameSize * 0.78
        guard summarySize >= 8 else { return }
        y += nameSize * 1.5

        // Two lines, wrapped on the character budget the card allows. Cheaper
        // and more predictable than asking the text system to lay it out, and
        // the card is a fixed size so the budget never changes mid-frame.
        let perLine = max(6, Int(Double(plan.nameBudget) * Double(nameSize / summarySize) * 0.95))
        var remaining = Substring(summary)
        for line in 0..<2 where !remaining.isEmpty {
            let isLast = line == 1
            var take = remaining.prefix(perLine)
            if take.count < remaining.count, !isLast,
               let space = take.lastIndex(of: " "), take.distance(from: take.startIndex, to: space) > perLine / 2 {
                take = take[take.startIndex..<space]
            }
            var text = String(take).trimmingCharacters(in: .whitespaces)
            if isLast, take.count < remaining.count { text += "…" }
            context.draw(
                Text(text)
                    .font(.system(size: summarySize))
                    .foregroundColor(Theme.textSecondary.opacity(alpha * 0.9)),
                at: CGPoint(x: left, y: y), anchor: .leading
            )
            remaining = remaining.dropFirst(take.count).drop(while: { $0 == " " })
            y += summarySize * 1.35
        }
    }

    /// Truncates to what the card can actually show.
    private func fit(_ name: String, budget: Int) -> String {
        guard name.count > budget else { return name }
        return String(name.prefix(max(1, budget - 1))) + "…"
    }

    // MARK: Universe node

    /// Breathing radius for one body.
    ///
    /// ±2% on a slow sine, phase-offset per node by a hash of its id, so the
    /// field is alive without anything pulsing in unison.
    private func universeRadius(
        _ arrays: GraphArrays, _ index: Int, camera: Camera, time: TimeInterval
    ) -> CGFloat {
        var radius = CGFloat(arrays.radii[index])
        if !model.reduceMotion {
            radius *= CGFloat(1 + 0.02 * sin(time * 0.6 + Double(arrays.phase[index])))
        }
        return radius * camera.zoom
    }

    /// The additive glow. Drawn into a context whose blend mode is already set,
    /// so overlapping halos in a dense cluster genuinely brighten each other —
    /// that emergent glow is free and is most of why the view reads as light
    /// rather than as circles.
    private func drawHalo(
        _ context: inout GraphicsContext, arrays: GraphArrays, index: Int,
        at screen: CGPoint, camera: Camera, alpha: Double, time: TimeInterval,
        searchScore: Double?
    ) {
        guard alpha > 0.01 else { return }
        let screenRadius = universeRadius(arrays, index, camera: camera, time: time)

        let isSelected = model.selected == index
        let boost = isSelected ? 1.9
            : (model.hovered == index ? 1.4 : (searchScore != nil ? 1.5 : 1.0))
        let haloRadius = screenRadius * 3.4 * boost
        guard haloRadius > 1.2 else { return }

        context.opacity = alpha * Double(arrays.brightness[index]) * (isSelected ? 1 : 0.82)
        context.draw(
            GlowAtlas.shared.glow(hue: arrays.hues[index],
                                  bucket: GlowAtlas.bucket(forRadius: haloRadius)),
            in: CGRect(x: screen.x - haloRadius, y: screen.y - haloRadius,
                       width: haloRadius * 2, height: haloRadius * 2)
        )
    }

    /// The bright centre, plus the selection ring.
    private func drawCore(
        _ context: inout GraphicsContext, arrays: GraphArrays, index: Int,
        at screen: CGPoint, camera: Camera, alpha: Double, time: TimeInterval,
        diffState: DiffState? = nil
    ) {
        guard alpha > 0.01 else { return }
        let screenRadius = universeRadius(arrays, index, camera: camera, time: time)
        guard screenRadius > 0.8 else { return }

        let coreRadius: CGFloat = max(1, screenRadius * 0.55)
        let coreColour = Palette.color(
            hue: arrays.hues[index],
            brightness: Float(min(1, Double(arrays.brightness[index]) + 0.25)),
            saturation: 0.28, opacity: alpha
        )
        context.fill(
            Path(ellipseIn: CGRect(x: screen.x - coreRadius, y: screen.y - coreRadius,
                                   width: coreRadius * 2, height: coreRadius * 2)),
            with: .color(coreColour)
        )

        if let diffState {
            let ring = screenRadius * 2.6
            context.stroke(
                Path(ellipseIn: CGRect(x: screen.x - ring, y: screen.y - ring,
                                       width: ring * 2, height: ring * 2)),
                with: .color((diffState == .changed ? Theme.diffChanged : Theme.diffAffected)
                    .opacity(0.9 * alpha)),
                lineWidth: diffState == .changed ? 2 : 1.2
            )
        } else if model.selected == index {
            let ring = screenRadius * 2.6
            context.stroke(
                Path(ellipseIn: CGRect(x: screen.x - ring, y: screen.y - ring,
                                       width: ring * 2, height: ring * 2)),
                with: .color(Theme.accentBright.opacity(0.75 * alpha)),
                lineWidth: 1.5
            )
        }
    }

    // MARK: Labels

    private func drawLabels(
        _ context: inout GraphicsContext, arrays: GraphArrays, positions: [SIMD2<Float>],
        candidates: [Int32], camera: Camera, size: CGSize, lod: LODLevel,
        universeness: Double, restricted: Set<Int32>?, neighbourhood: Set<Int32>?
    ) {
        // Text shaping is the most expensive thing on screen and cannot be
        // batched. So: cull to the viewport *first*, then rank, then cap —
        // sorting 1 500 candidates to draw 120 of them was pure waste.
        var onScreen: [(index: Int, point: CGPoint)] = []
        onScreen.reserveCapacity(min(candidates.count, 400))

        for raw in candidates {
            let index = Int(raw)
            guard index < positions.count else { continue }
            if let restricted, !restricted.contains(raw) { continue }
            if let filtered = model.filteredOut, filtered.contains(raw) { continue }
            let screen = camera.worldToScreen(positions[index], viewport: size)
            guard screen.x > -40, screen.y > -20,
                  screen.x < size.width + 40, screen.y < size.height + 20 else { continue }
            onScreen.append((index, screen))
            if onScreen.count > 400 { break }
        }

        let budget = 120
        if onScreen.count > budget {
            // Selection and hover first, then the best-connected: if labels
            // must be dropped, drop the ones that explain least.
            onScreen.sort { lhs, rhs in
                if (model.selected == lhs.index) != (model.selected == rhs.index) {
                    return model.selected == lhs.index
                }
                if (model.hovered == lhs.index) != (model.hovered == rhs.index) {
                    return model.hovered == lhs.index
                }
                return arrays.degree[lhs.index] > arrays.degree[rhs.index]
            }
            onScreen = Array(onScreen.prefix(budget))
        }

        // Placed label rectangles, so a name is never printed on top of another.
        // Without this a dense cluster prints twenty names in the same square
        // inch and none of them can be read — worse than showing none at all.
        // `onScreen` is already ordered by importance, so the labels that win
        // the space are the selection, the hover, then the best-connected.
        var placed: [CGRect] = []
        placed.reserveCapacity(onScreen.count)

        for entry in onScreen {
            var opacity = lod.labelOpacity
            if let neighbourhood, !neighbourhood.contains(Int32(entry.index)) { opacity *= 0.2 }
            if !model.searchScores.isEmpty {
                // While searching, a hit's name is the single most useful thing
                // on screen — so hits get a label whatever the zoom says, and
                // everything else gives up its own to make room.
                opacity = model.searchScores[entry.index] != nil ? 1 : opacity * 0.15
            }
            guard opacity > 0.05 else { continue }

            // Fades in with the morph so names do not pop the instant the
            // view crosses the halfway point.
            opacity *= min(1, max(0, (universeness - 0.5) * 4))
            guard opacity > 0.05 else { continue }
            let offset = CGFloat(arrays.radii[entry.index]) * camera.zoom * 1.9 + 9
            let name = truncate(arrays.names[entry.index])

            // Estimated rather than measured: `GraphicsContext` can only give a
            // real size by resolving the text, which is the expensive half of
            // drawing it. 5.6pt per character at 11pt is close enough to keep
            // labels apart, and being slightly generous errs toward showing
            // fewer, readable names.
            let estimated = CGSize(width: CGFloat(name.count) * 5.6 + 6, height: 14)
            let box = CGRect(
                x: entry.point.x - estimated.width / 2,
                y: entry.point.y + offset,
                width: estimated.width, height: estimated.height
            )
            let isPriority = model.selected == entry.index
                || model.hovered == entry.index
                || model.searchScores[entry.index] != nil
            if !isPriority, placed.contains(where: { $0.intersects(box) }) { continue }
            placed.append(box)

            context.draw(
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary.opacity(opacity)),
                at: CGPoint(x: entry.point.x, y: entry.point.y + offset),
                anchor: .top
            )
        }
    }

    /// Matches upstream's 24-character cap so names line up the same way.
    private func truncate(_ name: String) -> String {
        name.count <= 24 ? name : String(name.prefix(22)) + "…"
    }
}
