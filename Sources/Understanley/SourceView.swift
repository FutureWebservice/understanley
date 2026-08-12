import Foundation

/// Lexical syntax needed to tell code from not-code in a given language.
struct CommentSyntax: Sendable {
    var lineComment: [String] = ["//"]
    var blockComment: [(open: String, close: String)] = [(open: "/*", close: "*/")]
    /// Quote characters that open a single-line string.
    var stringDelimiters: [Character] = ["\"", "'"]
    /// Delimiters that open a string spanning multiple lines (template
    /// literals, Python triple quotes, Swift `"""`).
    var multilineStrings: [(open: String, close: String)] = []
    var escape: Character? = "\\"
    /// True when a `#` at line start is a comment rather than a preprocessor
    /// directive worth keeping.
    var hashIsComment: Bool = false

    static let cStyle = CommentSyntax()

    static let jsStyle = CommentSyntax(
        lineComment: ["//"],
        blockComment: [(open: "/*", close: "*/")],
        stringDelimiters: ["\"", "'"],
        multilineStrings: [(open: "`", close: "`")]
    )

    static let python = CommentSyntax(
        lineComment: ["#"],
        blockComment: [],
        stringDelimiters: ["\"", "'"],
        // Triple quotes must be tried before single ones, which the scanner
        // guarantees by checking `multilineStrings` first.
        multilineStrings: [(open: "\"\"\"", close: "\"\"\""), (open: "'''", close: "'''")],
        hashIsComment: true
    )

    static let ruby = CommentSyntax(
        lineComment: ["#"],
        blockComment: [(open: "=begin", close: "=end")],
        stringDelimiters: ["\"", "'"],
        hashIsComment: true
    )

    static let swiftStyle = CommentSyntax(
        lineComment: ["//"],
        blockComment: [(open: "/*", close: "*/")],
        stringDelimiters: ["\""],
        multilineStrings: [(open: "\"\"\"", close: "\"\"\"")]
    )

    static let shell = CommentSyntax(
        lineComment: ["#"],
        blockComment: [],
        stringDelimiters: ["\"", "'"],
        hashIsComment: true
    )

    static let sqlStyle = CommentSyntax(
        lineComment: ["--"],
        blockComment: [(open: "/*", close: "*/")],
        stringDelimiters: ["'", "\""]
    )

    static let hashOnly = CommentSyntax(
        lineComment: ["#"],
        blockComment: [],
        stringDelimiters: ["\"", "'"],
        hashIsComment: true
    )

    /// No comments at all — used for formats where `#` and `//` are ordinary
    /// content (JSON, CSV).
    static let none = CommentSyntax(
        lineComment: [],
        blockComment: [],
        stringDelimiters: ["\""]
    )
}

/// A source file prepared for structural extraction.
///
/// The central idea is `code`: a copy of the source with every comment and
/// string literal blanked to spaces, character for character. Regex and brace
/// counting run against that, so a `"function foo()"` inside a string literal
/// or a `{` inside a comment cannot be mistaken for real syntax — the single
/// largest source of false positives in any pattern-based extractor.
///
/// Positions are preserved exactly, so a match found in `code` can be read back
/// out of `lines` at the same index and offset.
struct SourceView {
    /// Original lines, without terminators.
    let lines: [String]

    /// Lines with comments removed but **string literals intact**.
    ///
    /// This is what the extractors match against. Comments must go — a
    /// commented-out `import` is not an import — but string contents must
    /// stay, because for most parsers the string *is* the payload: the module
    /// path in `from "../types.js"`, the key in a JSON object, the type name in
    /// a Terraform `resource "aws_s3_bucket" "logs"`. Blanking strings here
    /// silently empties every one of those.
    let text: [String]

    /// Lines with comments **and** string contents removed.
    ///
    /// Used only for brace arithmetic, where a `{` inside a string literal
    /// must not count toward nesting depth.
    let structure: [String]

    /// Brace nesting depth at the start of each line.
    let depthBefore: [Int]
    /// Leading-whitespace width of each line, tabs counted as one. Used by
    /// indentation-scoped languages.
    let indent: [Int]

    var count: Int { lines.count }

    init(source: String, syntax: CommentSyntax) {
        var rawLines = source.components(separatedBy: "\n")
        // A trailing newline yields one phantom empty element; drop it so line
        // counts agree with `wc -l`.
        if rawLines.count > 1, rawLines[rawLines.count - 1].isEmpty { rawLines.removeLast() }
        lines = rawLines
        let blanked = Self.blank(rawLines, syntax: syntax)
        text = blanked.text
        structure = blanked.structure

        var depths: [Int] = []
        depths.reserveCapacity(structure.count)
        var depth = 0
        for line in structure {
            depths.append(depth)
            for ch in line {
                if ch == "{" || ch == "(" || ch == "[" { depth += 1 }
                else if ch == "}" || ch == ")" || ch == "]" { depth = max(0, depth - 1) }
            }
        }
        depthBefore = depths

        indent = rawLines.map { line in
            var n = 0
            for ch in line {
                if ch == " " { n += 1 } else if ch == "\t" { n += 1 } else { break }
            }
            return n
        }
    }

    // MARK: - Blanking

    private enum Mode {
        case normal
        case blockComment(close: String)
        case multilineString(close: String)
    }

    /// Produces both views in a single pass. They stay character-for-character
    /// aligned with the original, so an offset found in one is valid in all
    /// three.
    private static func blank(
        _ lines: [String], syntax: CommentSyntax
    ) -> (text: [String], structure: [String]) {
        var textOut: [String] = []
        var structureOut: [String] = []
        textOut.reserveCapacity(lines.count)
        structureOut.reserveCapacity(lines.count)
        var mode = Mode.normal

        for line in lines {
            let chars = Array(line)
            var result = [Character](repeating: " ", count: chars.count)
            var stringy = [Character](repeating: " ", count: chars.count)
            var i = 0

            while i < chars.count {
                switch mode {
                case .blockComment(let close):
                    if matches(chars, at: i, close) {
                        i += close.count
                        mode = .normal
                    } else {
                        i += 1
                    }

                case .multilineString(let close):
                    if matches(chars, at: i, close) {
                        for k in i..<min(i + close.count, chars.count) { stringy[k] = chars[k] }
                        i += close.count
                        mode = .normal
                    } else {
                        stringy[i] = chars[i]
                        i += 1
                    }

                case .normal:
                    // Line comment: blank the remainder and stop.
                    if let token = syntax.lineComment.first(where: { matches(chars, at: i, $0) }) {
                        _ = token
                        i = chars.count
                        continue
                    }
                    // Block comment.
                    if let pair = syntax.blockComment.first(where: { matches(chars, at: i, $0.open) }) {
                        i += pair.open.count
                        mode = .blockComment(close: pair.close)
                        continue
                    }
                    // Multi-line string. Checked before single-character
                    // delimiters so `"""` is not read as an empty `""`
                    // followed by a stray quote.
                    if let pair = syntax.multilineStrings.first(where: { matches(chars, at: i, $0.open) }) {
                        for k in i..<min(i + pair.open.count, chars.count) { stringy[k] = chars[k] }
                        i += pair.open.count
                        mode = .multilineString(close: pair.close)
                        continue
                    }
                    // Single-line string: consume through the closing quote,
                    // honouring escapes. An unterminated quote ends at the line
                    // break, which is what the language would do too. The
                    // characters are kept in `text` and dropped from
                    // `structure`.
                    if syntax.stringDelimiters.contains(chars[i]) {
                        let quote = chars[i]
                        stringy[i] = chars[i]
                        i += 1
                        while i < chars.count {
                            if let esc = syntax.escape, chars[i] == esc {
                                for k in i..<min(i + 2, chars.count) { stringy[k] = chars[k] }
                                i += 2
                                continue
                            }
                            stringy[i] = chars[i]
                            if chars[i] == quote { i += 1; break }
                            i += 1
                        }
                        continue
                    }
                    result[i] = chars[i]
                    stringy[i] = chars[i]
                    i += 1
                }
            }
            textOut.append(String(stringy))
            structureOut.append(String(result))
        }
        return (textOut, structureOut)
    }

    private static func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
        let tokenChars = Array(token)
        guard !tokenChars.isEmpty, index + tokenChars.count <= chars.count else { return false }
        for (offset, ch) in tokenChars.enumerated() where chars[index + offset] != ch {
            return false
        }
        return true
    }

    // MARK: - Block spans

    /// Finds the line closing the brace block opened on or after `line`.
    ///
    /// Returns `line` itself when the declaration has no body (an interface
    /// method, an abstract signature, a one-line arrow function), so callers
    /// always get a usable range rather than having to special-case nil.
    func blockEnd(from line: Int, open: Character = "{", close: Character = "}") -> Int {
        guard line < structure.count else { return line }
        var depth = 0
        var started = false

        for index in line..<structure.count {
            for ch in structure[index] {
                if ch == open {
                    depth += 1
                    started = true
                } else if ch == close, started {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            // A declaration whose brace has not appeared within a few lines is
            // a signature, not a block — stop rather than swallowing the next
            // declaration's body.
            if !started, index > line + 2 { return line }
        }
        return started ? structure.count - 1 : line
    }

    /// Finds the last line of an indentation-scoped block starting at `line`
    /// (Python, YAML). The block ends at the first later non-blank line
    /// indented no further than the header.
    func indentBlockEnd(from line: Int) -> Int {
        guard line < lines.count else { return line }
        let base = indent[line]
        var end = line
        var index = line + 1
        while index < lines.count {
            if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                if indent[index] <= base { break }
                end = index
            }
            index += 1
        }
        return end
    }

    /// Line indices at brace depth zero — i.e. top-level declarations.
    ///
    /// This is both a large speed win (most lines in a source file are nested
    /// and can be skipped without running a single regex) and a faithfulness
    /// win: upstream's tree-sitter extractors only walk direct children of the
    /// root node, so nested declarations are invisible to them too.
    var topLevelLines: [Int] {
        (0..<structure.count).filter { depthBefore[$0] == 0 }
    }

    /// A line with comments stripped and string literals intact, trimmed.
    /// This is the view extractors should match against.
    func trimmedCode(_ index: Int) -> String {
        guard index < text.count else { return "" }
        return text[index].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Regex helpers

/// Compiled-once regular expressions.
///
/// `NSRegularExpression` compilation is expensive enough to matter when it
/// happens per file across a 10 000-file repository, so every pattern in the
/// extractors is a `static let` built through this.
enum Rx {
    static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // A malformed literal here is a programming error, not user input.
        // Falling back to a never-matching expression keeps the app running and
        // surfaces the mistake as "this extractor finds nothing" rather than a
        // crash on some user's machine.
        (try? NSRegularExpression(pattern: pattern, options: options))
            ?? NSRegularExpression()
    }
}

extension NSRegularExpression {
    /// First match in `text`, as capture-group strings. Index 0 is the whole
    /// match. Absent groups come back as nil.
    func firstGroups(in text: String) -> [String?]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let r = Range(match.range(at: index), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// The `index`th capture group of the first match, or nil when the pattern
    /// does not match or that group did not participate.
    ///
    /// Preferred over indexing `firstGroups` directly: the array elements are
    /// themselves optional, so a raw subscript yields a double optional that is
    /// easy to unwrap incorrectly.
    func group(_ index: Int, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = firstMatch(in: text, options: [], range: range),
              index < match.numberOfRanges,
              let r = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[r])
    }

    /// Every match in `text`, as capture-group strings.
    func allGroups(in text: String) -> [[String?]] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return matches(in: text, options: [], range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }
        }
    }

    func matches(_ text: String) -> Bool {
        firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }
}

// MARK: - Parameter parsing

enum ParamParser {
    /// Splits a parameter list into names.
    ///
    /// Handles nesting so `Map<String, Int>` and `f(a = (1, 2))` count as one
    /// parameter, strips type annotations, defaults, decorators and modifiers,
    /// and normalises rest/variadic forms. Returns names only — types are not
    /// part of the graph.
    static func names(from parameterList: String, dropSelf: Bool = false) -> [String] {
        let parts = splitTopLevel(parameterList)
        var out: [String] = []
        for part in parts {
            guard let name = normalize(part) else { continue }
            if dropSelf, name == "self" || name == "cls" { continue }
            out.append(name)
        }
        return out
    }

    /// Splits on commas that are not inside brackets, braces, parens, angle
    /// brackets or quotes.
    static func splitTopLevel(_ text: String, separator: Character = ",") -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?

        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'", "`":
                quote = ch
                current.append(ch)
            case "(", "[", "{", "<":
                depth += 1
                current.append(ch)
            case ")", "]", "}", ">":
                depth -= 1
                current.append(ch)
            case separator where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    private static let modifiers: Set<String> = [
        "public", "private", "protected", "internal", "readonly", "final",
        "const", "let", "var", "in", "out", "ref", "params", "val", "inout",
        "@escaping", "@autoclosure", "override", "open", "static",
    ]

    private static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Drop a default value: everything from the first top-level `=`.
        if let eq = topLevelIndex(of: "=", in: text) {
            text = String(text[text.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        }
        // Drop a type annotation: everything from the first top-level `:`.
        if let colon = topLevelIndex(of: ":", in: text) {
            text = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }

        // Variadic and rest forms keep their marker so the signature still
        // reads correctly in the UI.
        var prefix = ""
        for marker in ["...", "**", "*", "&"] where text.hasPrefix(marker) {
            prefix = marker == "&" ? "" : marker
            text = String(text.dropFirst(marker.count))
            break
        }

        // Destructured parameters have no single name; report the shape.
        if text.hasPrefix("{") { return prefix + "{…}" }
        if text.hasPrefix("[") { return prefix + "[…]" }

        // Drop leading modifiers and decorators, and any remaining type words
        // in `Type name` languages — the last identifier is the name.
        var words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        words.removeAll { modifiers.contains($0) || $0.hasPrefix("@") }
        guard var name = words.last else { return nil }

        // Trim anything left over from an unbalanced construct.
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>,;*&?"))
        guard !name.isEmpty, name.first.map({ $0.isLetter || $0 == "_" || $0 == "$" }) == true else {
            return nil
        }
        return prefix + name
    }

    private static func topLevelIndex(of target: Character, in text: String) -> String.Index? {
        var depth = 0
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if let q = quote {
                if ch == q { quote = nil }
            } else {
                switch ch {
                case "\"", "'", "`": quote = ch
                case "(", "[", "{", "<": depth += 1
                case ")", "]", "}", ">": depth -= 1
                case target where depth == 0: return index
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Extracts the balanced parenthesised group starting at or after `start`.
    /// Returns the inner text and the index just past the closing paren.
    static func balanced(
        _ text: String,
        from start: String.Index,
        open: Character = "(",
        close: Character = ")"
    ) -> (inner: String, end: String.Index)? {
        guard let openIndex = text[start...].firstIndex(of: open) else { return nil }
        var depth = 0
        var index = openIndex
        var quote: Character?
        while index < text.endIndex {
            let ch = text[index]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == open {
                depth += 1
            } else if ch == close {
                depth -= 1
                if depth == 0 {
                    let inner = String(text[text.index(after: openIndex)..<index])
                    return (inner, text.index(after: index))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
