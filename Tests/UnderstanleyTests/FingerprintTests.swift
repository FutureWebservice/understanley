import XCTest

@testable import Understanley

/// The cosmetic-versus-structural distinction is the whole value of
/// fingerprinting: get it wrong in one direction and every keystroke triggers a
/// full rebuild, get it wrong in the other and the graph silently goes stale.
final class FingerprintTests: XCTestCase {
    private func fingerprint(_ source: String, path: String = "a.ts") -> Fingerprints.FileFingerprint {
        let analysis = ExtractorRegistry.shared.analyze(
            source: source, language: LanguageRegistry.language(for: path), path: path
        )
        return Fingerprints.fingerprint(source: source, analysis: analysis)
    }

    func testIdenticalContentIsUnchanged() {
        let source = "export function a(x: string) { return x; }\n"
        XCTAssertEqual(Fingerprints.compare(fingerprint(source), fingerprint(source)), .none)
    }

    func testCommentAndBodyEditsAreCosmetic() {
        let before = """
        export function greet(name: string): string {
          return "hi " + name;
        }
        """
        let after = """
        // A friendlier greeting.
        export function greet(name: string): string {
          const prefix = "hello ";
          return prefix + name;
        }
        """
        // Signature, exports and imports are all unchanged, so nothing the
        // graph records has moved.
        XCTAssertEqual(Fingerprints.compare(fingerprint(before), fingerprint(after)), .cosmetic)
    }

    func testSignatureChangeIsStructural() {
        let before = "export function greet(name: string) { return name; }"
        let after = "export function greet(name: string, loud: boolean) { return name; }"
        XCTAssertEqual(Fingerprints.compare(fingerprint(before), fingerprint(after)), .structural)
    }

    func testImportChangeIsStructural() {
        let before = "import { a } from './a';\nexport const x = a;"
        let after = "import { a } from './b';\nexport const x = a;"
        XCTAssertEqual(Fingerprints.compare(fingerprint(before), fingerprint(after)), .structural)
    }

    func testReorderedImportsAreCosmetic() {
        // Import order carries no meaning in the graph, and formatters shuffle
        // it constantly.
        let before = "import { a } from './a';\nimport { b } from './b';\nexport const x = 1;"
        let after = "import { b } from './b';\nimport { a } from './a';\nexport const x = 1;"
        XCTAssertEqual(Fingerprints.compare(fingerprint(before), fingerprint(after)), .cosmetic)
    }

    func testLargeSizeChangeIsStructural() {
        let before = """
        export function work() {
          return 1;
        }
        """
        let body = (0..<40).map { "  const v\($0) = \($0);" }.joined(separator: "\n")
        let after = "export function work() {\n\(body)\n  return 1;\n}"
        // Same signature, but the function tripled — its summary is now wrong.
        XCTAssertEqual(Fingerprints.compare(fingerprint(before), fingerprint(after)), .structural)
    }

    func testUnparsedFilesAreTreatedConservatively() {
        let old = Fingerprints.FileFingerprint(
            contentHash: "aaa", functions: [], classes: [], imports: [], exports: [],
            hasStructuralAnalysis: false
        )
        let new = Fingerprints.FileFingerprint(
            contentHash: "bbb", functions: [], classes: [], imports: [], exports: [],
            hasStructuralAnalysis: false
        )
        // No structure to compare means no basis to call it cosmetic.
        XCTAssertEqual(Fingerprints.compare(old, new), .structural)
    }

    func testUpdateClassificationThresholds() {
        func changes(structural: Int, added: Int = 0, deleted: Int = 0,
                     unchanged: Int = 0) -> Fingerprints.ChangeSet {
            var set = Fingerprints.ChangeSet()
            set.structural = (0..<structural).map { "src/s\($0).ts" }
            set.added = (0..<added).map { "src/a\($0).ts" }
            set.deleted = (0..<deleted).map { "src/d\($0).ts" }
            set.unchanged = (0..<unchanged).map { "src/u\($0).ts" }
            return set
        }

        XCTAssertEqual(Fingerprints.classify(changes(structural: 0), totalFilesInGraph: 100), .skip)
        XCTAssertEqual(Fingerprints.classify(changes(structural: 3, unchanged: 200),
                                             totalFilesInGraph: 200), .partial)
        XCTAssertEqual(Fingerprints.classify(changes(structural: 15, unchanged: 200),
                                             totalFilesInGraph: 200), .architecture)
        XCTAssertEqual(Fingerprints.classify(changes(structural: 40), totalFilesInGraph: 500), .full)
        // More than half the project, even though it is under 30 files.
        XCTAssertEqual(Fingerprints.classify(changes(structural: 6), totalFilesInGraph: 10), .full)
    }

    func testNewTopLevelDirectoryForcesArchitectureRerun() {
        var set = Fingerprints.ChangeSet()
        set.unchanged = ["src/a.ts", "src/b.ts"]
        set.added = ["services/new.ts"]
        // A brand-new top-level directory is a change of shape, not of content,
        // so layers have to be recomputed even though only one file moved.
        XCTAssertEqual(Fingerprints.classify(set, totalFilesInGraph: 3), .architecture)

        var sameDir = Fingerprints.ChangeSet()
        sameDir.unchanged = ["src/a.ts", "src/b.ts"]
        sameDir.added = ["src/c.ts"]
        XCTAssertEqual(Fingerprints.classify(sameDir, totalFilesInGraph: 3), .partial)
    }
}
