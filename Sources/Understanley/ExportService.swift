import AppKit
import Foundation

/// Gets the graph out of the app.
///
/// Four formats, for four genuinely different jobs: JSON to keep working with
/// it, SVG to put in a document, PNG to paste into a message, and a
/// self-contained HTML page to send to someone who has neither this app nor
/// Claude Code. That last one replaces upstream's `npx` viewer package —
/// a single file, no server, no install.
enum ExportService {
    enum Format: String, CaseIterable, Identifiable {
        case json, svg, png, html

        var id: String { rawValue }

        var label: String {
            switch self {
            case .json: return "Graph data (JSON)"
            case .svg: return "Vector image (SVG)"
            case .png: return "Image (PNG)"
            case .html: return "Shareable page (HTML)"
            }
        }

        var detail: String {
            switch self {
            case .json: return "Opens in the Claude Code plugin's dashboard too."
            case .svg: return "Scales cleanly, for documents and slides."
            case .png: return "2× resolution, for pasting into a message."
            case .html: return "One file, works offline, no install needed."
            }
        }

        var fileExtension: String { rawValue }
    }

    /// Writes `format` to `url`.
    static func write(
        _ format: Format, graph: KnowledgeGraph, arrays: GraphArrays,
        positions: [SIMD2<Float>], to url: URL
    ) throws {
        switch format {
        case .json:
            try JSONFile.encoder().encode(graph).write(to: url, options: .atomic)
        case .svg:
            try Data(svg(graph: graph, arrays: arrays, positions: positions).utf8)
                .write(to: url, options: .atomic)
        case .png:
            guard let data = png(graph: graph, arrays: arrays, positions: positions) else {
                throw ExportError.renderFailed
            }
            try data.write(to: url, options: .atomic)
        case .html:
            try Data(html(graph: graph, arrays: arrays, positions: positions).utf8)
                .write(to: url, options: .atomic)
        }
    }

    enum ExportError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "Could not render the image." }
    }

    // MARK: - Geometry

    private struct Frame {
        var minX: Float, minY: Float, width: Float, height: Float
    }

    private static func frame(_ positions: [SIMD2<Float>], padding: Float = 80) -> Frame {
        let finite = positions.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finite.first else { return Frame(minX: 0, minY: 0, width: 1, height: 1) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in finite {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return Frame(
            minX: minX - padding, minY: minY - padding,
            width: max(1, maxX - minX + padding * 2),
            height: max(1, maxY - minY + padding * 2)
        )
    }

    /// The graph's own palette as CSS-ready hex, so an export looks like the app.
    private static func hex(hue: Float, brightness: Float, saturation: Float = 0.62) -> String {
        let colour = NSColor(
            hue: CGFloat(hue.truncatingRemainder(dividingBy: 360) / 360),
            saturation: CGFloat(saturation), brightness: CGFloat(brightness), alpha: 1
        ).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int(colour.redComponent * 255), Int(colour.greenComponent * 255),
            Int(colour.blueComponent * 255)
        )
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - SVG

    static func svg(
        graph: KnowledgeGraph, arrays: GraphArrays, positions: [SIMD2<Float>]
    ) -> String {
        let box = frame(positions)
        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(floorToInt(Float(box.minX))) \(floorToInt(Float(box.minY))) \
        \(floorToInt(Float(box.width))) \(floorToInt(Float(box.height)))" width="\(floorToInt(Float(box.width)))" height="\(floorToInt(Float(box.height)))">
        <rect x="\(floorToInt(Float(box.minX)))" y="\(floorToInt(Float(box.minY)))" width="\(floorToInt(Float(box.width)))" \
        height="\(floorToInt(Float(box.height)))" fill="#0A0A12"/>

        """

        // Edges first, so nodes sit on top.
        out += "<g stroke-linecap=\"round\">\n"
        for e in 0..<arrays.edgeCount {
            let a = Int(arrays.edgeSource[e]), b = Int(arrays.edgeTarget[e])
            guard a < positions.count, b < positions.count else { continue }
            let colour = hex(hue: arrays.hues[a], brightness: 0.75, saturation: 0.5)
            out += "<line x1=\"\(Int(positions[a].x))\" y1=\"\(Int(positions[a].y))\" "
            out += "x2=\"\(Int(positions[b].x))\" y2=\"\(Int(positions[b].y))\" "
            out += "stroke=\"\(colour)\" stroke-width=\"1\" stroke-opacity=\"0.22\"/>\n"
        }
        out += "</g>\n<g>\n"

        for index in 0..<min(arrays.count, positions.count) {
            let p = positions[index]
            guard p.x.isFinite, p.y.isFinite else { continue }
            let radius = max(3, arrays.radii[index])
            let colour = hex(hue: arrays.hues[index], brightness: arrays.brightness[index])
            out += "<circle cx=\"\(floorToInt(Float(p.x)))\" cy=\"\(floorToInt(Float(p.y)))\" r=\"\(floorToInt(Float(radius)))\" "
            out += "fill=\"\(colour)\" fill-opacity=\"0.9\"/>\n"
        }
        out += "</g>\n"

        // Labels only for the best-connected: every name at this scale is an
        // unreadable smear, and the hubs are what identify the picture.
        let labelled = (0..<arrays.count)
            .sorted { arrays.degree[$0] > arrays.degree[$1] }
            .prefix(60)
        out += "<g font-family=\"-apple-system, system-ui, sans-serif\" font-size=\"11\" "
        out += "fill=\"#F5F0EB\" fill-opacity=\"0.85\" text-anchor=\"middle\">\n"
        for index in labelled where index < positions.count {
            let p = positions[index]
            guard p.x.isFinite, p.y.isFinite else { continue }
            out += "<text x=\"\(floorToInt(Float(p.x)))\" y=\"\(floorToInt(Float(p.y) - arrays.radii[index] - 6))\">"
            out += escape(arrays.names[index]) + "</text>\n"
        }
        out += "</g>\n</svg>\n"
        return out
    }

    // MARK: - PNG

    /// Largest bitmap worth producing. Beyond this the file is unwieldy and no
    /// screen can show it anyway.
    private static let maxPixels = 40_000_000

    static func png(
        graph: KnowledgeGraph, arrays: GraphArrays, positions: [SIMD2<Float>],
        preferredScale: CGFloat = 2
    ) -> Data? {
        let box = frame(positions)
        guard box.width > 0, box.height > 0 else { return nil }

        // A large graph at 2× asks for a gigapixel bitmap — the Universe layout
        // of a 1 500-node project is roughly 8 000 × 6 700 world units, which is
        // 212 megapixels once doubled. Refusing to export it would be the wrong
        // answer; scaling down to fit the budget gives the user their image.
        let requested = CGFloat(box.width) * preferredScale * CGFloat(box.height) * preferredScale
        let scale = requested > CGFloat(maxPixels)
            ? preferredScale * sqrt(CGFloat(maxPixels) / requested)
            : preferredScale

        let width = max(1, Int(CGFloat(box.width) * scale))
        let height = max(1, Int(CGFloat(box.height) * scale))

        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return nil }
        context.setFillColor(NSColor(red: 0.039, green: 0.039, blue: 0.07, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func point(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(
                x: CGFloat(p.x - box.minX) * scale,
                // CoreGraphics origin is bottom-left; the graph's is top-left.
                y: CGFloat(box.height - (p.y - box.minY)) * scale
            )
        }

        context.setLineWidth(scale)
        for e in 0..<arrays.edgeCount {
            let a = Int(arrays.edgeSource[e]), b = Int(arrays.edgeTarget[e])
            guard a < positions.count, b < positions.count,
                  positions[a].x.isFinite, positions[b].x.isFinite else { continue }
            let colour = NSColor(
                hue: CGFloat(arrays.hues[a].truncatingRemainder(dividingBy: 360) / 360),
                saturation: 0.5, brightness: 0.75, alpha: 0.22
            )
            context.setStrokeColor(colour.cgColor)
            context.beginPath()
            context.move(to: point(positions[a]))
            context.addLine(to: point(positions[b]))
            context.strokePath()
        }

        for index in 0..<min(arrays.count, positions.count) {
            guard positions[index].x.isFinite, positions[index].y.isFinite else { continue }
            let centre = point(positions[index])
            let radius = max(3, CGFloat(arrays.radii[index])) * scale
            context.setFillColor(NSColor(
                hue: CGFloat(arrays.hues[index].truncatingRemainder(dividingBy: 360) / 360),
                saturation: 0.62, brightness: CGFloat(arrays.brightness[index]), alpha: 0.92
            ).cgColor)
            context.fillEllipse(in: CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2
            ))
        }

        guard let cgImage = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
    }

    // MARK: - Self-contained HTML

    /// One HTML file: the graph, a pan-and-zoom canvas, search, and a details
    /// panel. No CDN, no build step, no server — it works from a double-click
    /// and survives being emailed.
    static func html(
        graph: KnowledgeGraph, arrays: GraphArrays, positions: [SIMD2<Float>]
    ) -> String {
        // The payload is a compact parallel-array form rather than the full
        // schema: a 1 500-node graph with prose is megabytes, and the viewer
        // only needs what it draws plus what it shows on click.
        var nodesJSON: [[String: Any]] = []
        nodesJSON.reserveCapacity(arrays.count)
        let summaries = Dictionary(
            graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
        )

        for index in 0..<min(arrays.count, positions.count) {
            let p = positions[index]
            guard p.x.isFinite, p.y.isFinite else { continue }
            let node = summaries[arrays.ids[index]]
            nodesJSON.append([
                "i": index,
                "n": arrays.names[index],
                "t": arrays.types[index].rawValue,
                "x": floorToInt(Float(p.x)), "y": floorToInt(Float(p.y)),
                "r": Int(max(3, arrays.radii[index])),
                "h": Int(arrays.hues[index]),
                "d": Int(arrays.degree[index]),
                "p": node?.filePath ?? "",
                "s": node.map { $0.isEnriched ? $0.summary : "" } ?? "",
                "g": node?.tags.joined(separator: " ") ?? "",
            ])
        }
        var edgesJSON: [[Int]] = []
        edgesJSON.reserveCapacity(arrays.edgeCount)
        for e in 0..<arrays.edgeCount {
            edgesJSON.append([Int(arrays.edgeSource[e]), Int(arrays.edgeTarget[e])])
        }

        let payload: [String: Any] = [
            "name": graph.project.name,
            "description": graph.project.description,
            "languages": graph.project.languages,
            "nodes": nodesJSON,
            "edges": edgesJSON,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"

        return """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(graph.project.name)) — knowledge graph</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { margin:0; background:#0A0A12; color:#F5F0EB;
                 font:14px/1.5 -apple-system, system-ui, "Segoe UI", sans-serif; overflow:hidden; }
          canvas { display:block; cursor:grab; }
          canvas.dragging { cursor:grabbing; }
          #bar { position:fixed; top:0; left:0; right:0; padding:10px 16px;
                 display:flex; gap:14px; align-items:center;
                 background:rgba(17,17,17,.86); backdrop-filter:blur(12px);
                 border-bottom:1px solid rgba(212,165,116,.14); z-index:2; }
          #title { font-weight:600; }
          #meta { color:#6B5F53; font-size:12px; }
          #q { flex:1; max-width:280px; padding:6px 10px; border-radius:7px;
               border:1px solid rgba(212,165,116,.18); background:#1A1A1A; color:#F5F0EB; }
          #panel { position:fixed; right:0; top:45px; bottom:0; width:320px; padding:18px;
                   background:rgba(20,20,20,.94); border-left:1px solid rgba(212,165,116,.14);
                   overflow:auto; display:none; z-index:2; }
          #panel.open { display:block; }
          #panel h2 { margin:0 0 2px; font-size:16px; }
          #panel .type { font-size:10px; letter-spacing:.06em; text-transform:uppercase; }
          #panel .path { font:11px ui-monospace, Menlo, monospace; color:#6B5F53;
                         word-break:break-all; margin:8px 0; }
          #panel .summary { color:#A39787; margin:10px 0; }
          #panel ul { list-style:none; padding:0; margin:8px 0; }
          #panel li { padding:4px 6px; border-radius:5px; cursor:pointer; font-size:12px; }
          #panel li:hover { background:rgba(212,165,116,.1); }
          #hint { position:fixed; left:16px; bottom:14px; color:#6B5F53; font-size:11px; z-index:2; }
        </style></head><body>
        <div id="bar">
          <span id="title"></span>
          <span id="meta"></span>
          <input id="q" placeholder="Search" autocomplete="off">
          <span id="hits" style="color:#6B5F53;font-size:12px"></span>
        </div>
        <canvas id="c"></canvas>
        <div id="panel"></div>
        <div id="hint">Drag to pan · scroll to zoom · click a node</div>
        <script>
        const G = \(json);
        const cv = document.getElementById('c'), ctx = cv.getContext('2d');
        const panel = document.getElementById('panel');
        document.getElementById('title').textContent = G.name;
        document.getElementById('meta').textContent =
          G.nodes.length + ' nodes · ' + G.edges.length + ' edges';

        // Adjacency, so clicking a node can list what it connects to.
        const adj = new Map();
        for (const [a, b] of G.edges) {
          if (!adj.has(a)) adj.set(a, []); if (!adj.has(b)) adj.set(b, []);
          adj.get(a).push(b); adj.get(b).push(a);
        }
        const byIndex = new Map(G.nodes.map(n => [n.i, n]));

        let cam = { x: 0, y: 0, z: 1 }, selected = null, hits = new Set();

        function fit() {
          cv.width = innerWidth * devicePixelRatio;
          cv.height = innerHeight * devicePixelRatio;
          cv.style.width = innerWidth + 'px'; cv.style.height = innerHeight + 'px';
          ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
        }
        // Fitting the view needs a viewport that exists. This script runs during
        // parse, when `innerHeight` can still be 0 — and `innerHeight - 45` then
        // goes NEGATIVE, producing a negative zoom and a graph drawn inside-out
        // at a few pixels across. Clamp the inputs, clamp the result, and re-fit
        // once the page has actually laid out.
        function frameAll() {
          if (!G.nodes.length) return;
          const w = Math.max(1, innerWidth);
          const h = Math.max(1, innerHeight - 45);
          let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
          for (const n of G.nodes) {
            x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y);
            x1 = Math.max(x1, n.x); y1 = Math.max(y1, n.y);
          }
          const pad = 80;
          const z = Math.min(w / (x1 - x0 + pad * 2), h / (y1 - y0 + pad * 2));
          cam.z = Math.max(0.01, Math.min(4, z || 1));
          cam.x = (x0 + x1) / 2; cam.y = (y0 + y1) / 2;
        }
        const sx = n => (n.x - cam.x) * cam.z + innerWidth / 2;
        const sy = n => (n.y - cam.y) * cam.z + (innerHeight + 45) / 2;

        function draw() {
          ctx.fillStyle = '#0A0A12';
          ctx.fillRect(0, 0, innerWidth, innerHeight);
          const dim = hits.size > 0 || selected !== null;
          const near = selected === null ? null : new Set([selected, ...(adj.get(selected) || [])]);

          ctx.lineWidth = 1;
          for (const [a, b] of G.edges) {
            const na = byIndex.get(a), nb = byIndex.get(b);
            if (!na || !nb) continue;
            // A search hit stays lit even while a selection is dimming the
            // rest — otherwise searching with something selected reports a
            // count and shows nothing, which reads as broken.
            const lit = near ? ((near.has(a) && near.has(b))
                                || hits.has(a) || hits.has(b))
                             : (hits.size ? (hits.has(a) || hits.has(b)) : true);
            ctx.strokeStyle = 'hsla(' + na.h + ',50%,60%,' + (lit ? (dim ? .5 : .18) : .04) + ')';
            ctx.beginPath(); ctx.moveTo(sx(na), sy(na)); ctx.lineTo(sx(nb), sy(nb)); ctx.stroke();
          }
          for (const n of G.nodes) {
            const hit = hits.has(n.i);
            // A search with nothing selected used to leave `lit` true for every
            // node, so the toolbar reported "9 found" and the picture did not
            // change. Nine bodies among fifteen hundred are only findable if
            // the rest step back — and the floor rises for a hit so it is still
            // a visible dot when zoomed out.
            const lit = near ? (near.has(n.i) || hit) : (hits.size ? hit : true);
            const r = Math.max(hit ? 4 : 2, n.r * cam.z) * (hit ? 1.7 : 1);
            ctx.globalAlpha = lit ? 1 : .2;
            ctx.fillStyle = 'hsl(' + n.h + ',55%,' + (hit ? 78 : 62) + '%)';
            ctx.beginPath(); ctx.arc(sx(n), sy(n), r, 0, 6.283); ctx.fill();
            if (n.i === selected) {
              ctx.strokeStyle = '#E8C49A'; ctx.lineWidth = 2;
              ctx.beginPath(); ctx.arc(sx(n), sy(n), r + 5, 0, 6.283); ctx.stroke();
              ctx.lineWidth = 1;
            }
            ctx.globalAlpha = 1;
          }
          if (cam.z > .55) {
            ctx.font = '11px -apple-system, system-ui, sans-serif';
            ctx.textAlign = 'center'; ctx.fillStyle = 'rgba(245,240,235,.8)';
            const ranked = [...G.nodes].sort((a, b) => b.d - a.d).slice(0, 140);
            for (const n of ranked) {
              const x = sx(n), y = sy(n);
              if (x < -40 || y < 0 || x > innerWidth + 40 || y > innerHeight) continue;
              ctx.fillText(n.n.length > 24 ? n.n.slice(0, 22) + '…' : n.n,
                           x, y - Math.max(2, n.r * cam.z) - 5);
            }
          }
        }

        function show(i) {
          selected = i;
          const n = byIndex.get(i);
          if (!n) { panel.className = ''; draw(); return; }
          const links = (adj.get(i) || []).slice(0, 40)
            .map(j => byIndex.get(j)).filter(Boolean);
          panel.innerHTML =
            '<h2>' + esc(n.n) + '</h2>' +
            '<div class="type" style="color:hsl(' + n.h + ',55%,65%)">' + esc(n.t) + '</div>' +
            (n.p ? '<div class="path">' + esc(n.p) + '</div>' : '') +
            (n.s ? '<div class="summary">' + esc(n.s) + '</div>' : '') +
            (n.g ? '<div style="color:#6B5F53;font-size:11px">' + esc(n.g) + '</div>' : '') +
            '<div style="margin-top:14px;font-size:10px;letter-spacing:.06em;color:#6B5F53">' +
            'CONNECTIONS ' + (adj.get(i) || []).length + '</div><ul>' +
            links.map(m => '<li data-i="' + m.i + '">' + esc(m.n) + '</li>').join('') + '</ul>';
          panel.className = 'open';
          panel.querySelectorAll('li').forEach(li =>
            li.onclick = () => show(+li.dataset.i));
          draw();
        }
        const esc = s => String(s).replace(/[&<>"']/g,
          c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

        let drag = null;
        cv.addEventListener('mousedown', e => {
          drag = { x: e.clientX, y: e.clientY, moved: 0 }; cv.className = 'dragging';
        });
        addEventListener('mousemove', e => {
          if (!drag) return;
          const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
          drag.moved += Math.abs(dx) + Math.abs(dy);
          cam.x -= dx / cam.z; cam.y -= dy / cam.z;
          drag.x = e.clientX; drag.y = e.clientY; draw();
        });
        addEventListener('mouseup', e => {
          if (drag && drag.moved < 4) {
            let best = null, bestD = 400;
            for (const n of G.nodes) {
              const d = (sx(n) - e.clientX) ** 2 + (sy(n) - e.clientY) ** 2;
              if (d < bestD) { bestD = d; best = n.i; }
            }
            best === null ? (panel.className = '', selected = null, draw()) : show(best);
          }
          drag = null; cv.className = '';
        });
        cv.addEventListener('wheel', e => {
          e.preventDefault();
          const f = Math.exp(-e.deltaY * 0.002);
          const wx = (e.clientX - innerWidth / 2) / cam.z + cam.x;
          const wy = (e.clientY - (innerHeight + 45) / 2) / cam.z + cam.y;
          cam.z = Math.max(0.02, Math.min(4, cam.z * f));
          cam.x = wx - (e.clientX - innerWidth / 2) / cam.z;
          cam.y = wy - (e.clientY - (innerHeight + 45) / 2) / cam.z;
          draw();
        }, { passive: false });

        document.getElementById('q').addEventListener('input', e => {
          const q = e.target.value.trim().toLowerCase();
          hits = new Set();
          if (q) {
            for (const n of G.nodes) {
              if (n.n.toLowerCase().includes(q) || n.p.toLowerCase().includes(q)
                  || n.g.toLowerCase().includes(q) || n.s.toLowerCase().includes(q)) {
                hits.add(n.i);
              }
            }
          }
          document.getElementById('hits').textContent = q ? hits.size + ' found' : '';
          draw();
        });
        addEventListener('resize', () => { fit(); draw(); });
        addEventListener('keydown', e => {
          if (e.key === 'Escape') { panel.className = ''; selected = null; draw(); }
          if (e.key === '0') { frameAll(); draw(); }
        });

        function reframe() { fit(); frameAll(); draw(); }
        reframe();
        // Once after layout, and once after load: whichever gives a real
        // viewport first wins, and re-fitting an already-correct view is free.
        requestAnimationFrame(reframe);
        addEventListener('load', reframe);
        </script></body></html>
        """
    }

    // MARK: - Save panel

    /// Asks where to put it, then writes it.
    @MainActor
    static func run(
        _ format: Format, graph: KnowledgeGraph, arrays: GraphArrays, positions: [SIMD2<Float>]
    ) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(graph.project.name)-graph.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.title = format.label
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try write(format, graph: graph, arrays: arrays, positions: positions, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
