import Foundation

/// Watches a project tree and reports when its source actually changed.
///
/// The native replacement for upstream's post-commit hook. Strictly opt-in: a
/// tool that re-reads a folder you did not ask it to watch is a surprise, and
/// on a large repository it is an expensive one.
///
/// Three things make this usable rather than annoying:
///
/// - **Debounced.** A build, a branch switch or a formatter touches hundreds of
///   files in a burst. Re-analyzing per event would run the pipeline dozens of
///   times for one logical change.
/// - **Filtered.** `.ua/` is skipped, or writing the graph would trigger the
///   watcher that wrote it — a loop that never settles. So are the usual
///   build and VCS directories, which change constantly and mean nothing.
/// - **Cancellable and idempotent.** Starting twice on the same root is a no-op
///   rather than two streams delivering everything twice.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.futurewebservice.understanley.watcher")
    private(set) var root: String?

    /// Directory names never worth reacting to.
    ///
    /// `.ua` is the important one: the app writes the graph there itself, and
    /// without this the write wakes the watcher, which re-analyzes, which
    /// writes again.
    private static let ignoredComponents: Set<String> = [
        ".ua", ".understand-anything", ".git", ".svn", ".hg",
        "node_modules", ".next", "dist", "build", "target", "__pycache__",
        ".build", ".swiftpm", "DerivedData", ".venv", "venv",
    ]

    /// How long the tree must be quiet before anything happens.
    private static let quietPeriod: TimeInterval = 1.5

    /// Called on the main actor once the tree has settled.
    ///
    /// `@Sendable` as well as `@MainActor`: it is *invoked* on the main actor
    /// but it is *stored* here and read from the watcher's own dispatch queue,
    /// so the reference itself crosses isolation even though the call does not.
    private var onChange: (@Sendable @MainActor () -> Void)?

    deinit { stopStream() }

    /// Begins watching `root`. Starting on a root already being watched does
    /// nothing, so callers may call this freely on state changes.
    func start(root: String, onChange: @escaping @Sendable @MainActor () -> Void) {
        guard self.root != root || stream == nil else { return }
        stop()
        self.root = root
        self.onChange = onChange

        // `self` is passed unretained: the stream is invalidated in `stop` and
        // in `deinit`, both of which happen before this object goes away, so
        // the callback can never outlive it.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: Array(names.prefix(count)))
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.quietPeriod / 2,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            self.root = nil
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        stopStream()
        debounce?.cancel()
        debounce = nil
        root = nil
        onChange = nil
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String]) {
        guard paths.contains(where: Self.isInteresting) else { return }

        // Restart the timer on every burst, so the work runs once the tree has
        // been quiet — not once per event, and not while a build is mid-flight.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let handler = self?.onChange else { return }
            Task { @MainActor in handler() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + Self.quietPeriod, execute: work)
    }

    /// Whether a changed path is worth waking up for.
    static func isInteresting(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        if components.contains(where: { ignoredComponents.contains(String($0)) }) { return false }
        // Editors write `.swp`, `~` and atomic-save temporaries constantly.
        guard let last = components.last else { return false }
        if last.hasPrefix(".") || last.hasSuffix("~") { return false }
        let extension_ = PosixPath.fileExtension(String(last))
        return !["swp", ".swp", ".tmp", ".lock"].contains(extension_)
    }
}
