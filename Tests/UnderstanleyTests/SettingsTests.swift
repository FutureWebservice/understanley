import XCTest

@testable import Understanley

/// Settings that feed the canvas.
///
/// `CanvasInput` reads `UserDefaults` on every scroll event, so the value it
/// returns is the last line of defence between a hand-edited default and a
/// canvas that pans a thousand points per flick — or not at all. These tests
/// pin the clamp rather than the slider, because the slider is not the only way
/// the key can be set.
final class SettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: CanvasInput.speedKey)
        UserDefaults.standard.removeObject(forKey: CanvasInput.invertedKey)
        super.tearDown()
    }

    func testScrollSpeedDefaultsToUnchanged() {
        UserDefaults.standard.removeObject(forKey: CanvasInput.speedKey)
        XCTAssertEqual(CanvasInput.speed, 1)
    }

    func testScrollSpeedIsClampedBothWays() {
        UserDefaults.standard.set(500.0, forKey: CanvasInput.speedKey)
        XCTAssertEqual(CanvasInput.speed, 3)

        UserDefaults.standard.set(0.0, forKey: CanvasInput.speedKey)
        XCTAssertEqual(CanvasInput.speed, 0.25)

        UserDefaults.standard.set(-4.0, forKey: CanvasInput.speedKey)
        XCTAssertEqual(CanvasInput.speed, 0.25)
    }

    func testNonFiniteScrollSpeedFallsBackRatherThanPropagating() {
        // A NaN multiplier would put every node at an undefined coordinate and
        // blank the canvas until relaunch.
        UserDefaults.standard.set(Double.nan, forKey: CanvasInput.speedKey)
        XCTAssertEqual(CanvasInput.speed, 1)

        UserDefaults.standard.set(Double.infinity, forKey: CanvasInput.speedKey)
        XCTAssertEqual(CanvasInput.speed, 1)
    }

    func testScrollSpeedInRangePassesThrough() {
        UserDefaults.standard.set(2.5, forKey: CanvasInput.speedKey)
        XCTAssertEqual(CanvasInput.speed, 2.5)
    }

    func testInvertedDefaultsToNaturalDirection() {
        UserDefaults.standard.removeObject(forKey: CanvasInput.invertedKey)
        XCTAssertFalse(CanvasInput.isInverted)

        UserDefaults.standard.set(true, forKey: CanvasInput.invertedKey)
        XCTAssertTrue(CanvasInput.isInverted)
    }

    /// Every settings tab has to survive a round trip through `@AppStorage`,
    /// which stores the raw value and nothing else.
    func testSettingsTabsRoundTripThroughTheirRawValue() {
        for tab in SettingsView.Tab.allCases {
            XCTAssertEqual(SettingsView.Tab(rawValue: tab.rawValue), tab)
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.icon.isEmpty)
        }
    }
}
