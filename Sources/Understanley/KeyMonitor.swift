import AppKit
import SwiftUI

/// Window-wide keyboard shortcuts.
///
/// SwiftUI's `onKeyPress` is macOS 14 only, and the deployment target is 13.
/// A local `NSEvent` monitor works everywhere and is actually the better fit:
/// shortcuts should fire wherever focus happens to be on the canvas, not only
/// while one particular view holds it.
///
/// Typing is never intercepted — when a text field has focus, every keystroke
/// passes straight through.
struct KeyMonitor: ViewModifier {
    /// Returns true when the key was handled and should not propagate.
    let handler: (KeyStroke) -> Bool

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let stroke = KeyStroke(event: event)
                    // Typing is never intercepted — but the arrows, Return and
                    // Escape still are, even with a field focused. Search is a
                    // keyboard activity: the results sit under the field the
                    // user is typing in, and stepping through them must not
                    // require letting go of the keyboard first. The handler
                    // declines these when no list is open, so the field keeps
                    // its normal behaviour the rest of the time.
                    guard !Self.isEditingText || stroke.isNavigation else { return event }
                    return handler(stroke) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// True when the first responder is a text editor. SwiftUI's `TextField`
    /// is backed by an `NSTextView`, so this covers the search box and any
    /// future field without each needing to opt out.
    private static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }
}

/// One keystroke, in the terms the app cares about.
struct KeyStroke {
    let characters: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    /// What the key actually produced, with the layout applied.
    let typed: String

    init(event: NSEvent) {
        characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        typed = event.characters?.lowercased() ?? ""
        keyCode = event.keyCode
        modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    /// The character to match a shortcut against.
    ///
    /// `charactersIgnoringModifiers` is layout-dependent in a way that quietly
    /// breaks punctuation shortcuts: on a German keyboard "/" is Shift+7, so
    /// ignoring the modifier yields "7" and `case "/"` never fires. The same
    /// goes for "?" and ",". Prefer what the key actually produced, which is
    /// layout-correct, and fall back to the unmodified form when a dead key or
    /// composition leaves it empty. Letters are unaffected — both are lowercased.
    var character: String { typed.isEmpty ? characters : typed }

    var isEscape: Bool { keyCode == 53 }
    var isReturn: Bool { keyCode == 36 }
    var isLeftArrow: Bool { keyCode == 123 }
    var isRightArrow: Bool { keyCode == 124 }
    var isDownArrow: Bool { keyCode == 125 }
    var isUpArrow: Bool { keyCode == 126 }

    /// Keys that stay meaningful while a text field has focus.
    var isNavigation: Bool {
        isUpArrow || isDownArrow || isLeftArrow || isRightArrow || isReturn || isEscape
    }

    /// True when no modifier that changes meaning is held. Shift is allowed so
    /// `?` still reaches the help shortcut.
    var isPlain: Bool {
        modifiers.isDisjoint(with: [.command, .control, .option])
    }

    var hasCommand: Bool { modifiers.contains(.command) }
}

extension View {
    func onKeyStroke(_ handler: @escaping (KeyStroke) -> Bool) -> some View {
        modifier(KeyMonitor(handler: handler))
    }
}
