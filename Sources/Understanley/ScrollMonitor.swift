import AppKit
import SwiftUI

/// Trackpad and mouse-wheel input for the canvas.
///
/// SwiftUI has no scroll-wheel event on macOS 13, so this bridges `NSEvent`.
/// Both gestures are handled here rather than split between SwiftUI and AppKit,
/// because they have to agree about the cursor anchor — zooming toward a
/// different point than the one under the pointer feels immediately wrong.
struct ScrollMonitor: ViewModifier {
    /// Scroll delta in points, plus the cursor position in view coordinates.
    let onScroll: (CGSize, CGPoint) -> Void
    /// Multiplicative zoom factor, plus the cursor position.
    let onZoom: (Double, CGPoint) -> Void

    @State private var scrollMonitor: Any?
    @State private var magnifyMonitor: Any?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .onAppear { install(frame: geometry.frame(in: .global)) }
                .onDisappear(perform: remove)
                // The frame moves when the window resizes or the sidebar
                // toggles, and a stale frame would put the zoom anchor in the
                // wrong place.
                .onChange(of: geometry.frame(in: .global)) { frame in
                    remove()
                    install(frame: frame)
                }
        }
    }

    private func install(frame: CGRect) {
        guard scrollMonitor == nil else { return }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let point = locate(event, in: frame) else { return event }

            // A pinch on a trackpad arrives as a scroll with the command
            // modifier, and many mice send discrete lines rather than pixels.
            if event.modifierFlags.contains(.command) {
                let factor = 1 + event.scrollingDeltaY * 0.01
                onZoom(max(0.5, min(1.5, factor)), point)
                return nil
            }

            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            onScroll(
                CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale),
                point
            )
            return nil
        }

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            guard let point = locate(event, in: frame) else { return event }
            onZoom(1 + event.magnification, point)
            return nil
        }
    }

    private func remove() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        scrollMonitor = nil
        magnifyMonitor = nil
    }

    /// Cursor position in the view's own coordinates, or nil when the pointer
    /// is outside it — so scrolling the sidebar does not pan the canvas.
    private func locate(_ event: NSEvent, in frame: CGRect) -> CGPoint? {
        guard let window = event.window else { return nil }
        let inWindow = event.locationInWindow
        // AppKit's origin is bottom-left; SwiftUI's global space is top-left.
        let flipped = CGPoint(x: inWindow.x, y: window.contentLayoutRect.height - inWindow.y)
        guard frame.contains(flipped) else { return nil }
        return CGPoint(x: flipped.x - frame.minX, y: flipped.y - frame.minY)
    }
}

extension View {
    func onCanvasScroll(
        scroll: @escaping (CGSize, CGPoint) -> Void,
        zoom: @escaping (Double, CGPoint) -> Void
    ) -> some View {
        modifier(ScrollMonitor(onScroll: scroll, onZoom: zoom))
    }
}
