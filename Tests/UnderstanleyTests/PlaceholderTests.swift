import XCTest
@testable import Understanley

/// Replaced by the real suites as each subsystem lands; keeps `swift test`
/// green from the first commit so CI is meaningful immediately.
final class PlaceholderTests: XCTestCase {
    func testPosixPathBasics() {
        XCTAssertEqual(PosixPath.basename("src/app/main.ts"), "main.ts")
        XCTAssertEqual(PosixPath.directory(of: "src/app/main.ts"), "src/app")
        XCTAssertEqual(PosixPath.fileExtension("src/app/main.ts"), ".ts")
        XCTAssertEqual(PosixPath.stem("src/app/main.ts"), "main")
    }
}
