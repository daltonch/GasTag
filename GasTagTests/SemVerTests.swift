import XCTest
@testable import GasTag

/// Tests for the semantic-version comparison used to decide whether a firmware
/// update is available (issue #7). The historical bug dropped non-numeric
/// segments, so "1.2.0-beta" parsed to [1, 2] and shifted comparisons.
final class SemVerTests: XCTestCase {

    private func update(_ current: String, _ latest: String) -> Bool {
        GitHubReleaseService.isUpdateAvailable(currentVersion: current, latestVersion: latest)
    }

    func testEqualVersionsAreNotAnUpdate() {
        XCTAssertFalse(update("1.2.0", "1.2.0"))
    }

    func testNewerPatchIsAnUpdate() {
        XCTAssertTrue(update("1.2.0", "1.2.1"))
    }

    func testOlderPatchIsNotAnUpdate() {
        XCTAssertFalse(update("1.2.1", "1.2.0"))
    }

    /// The classic numeric-vs-lexical trap: 10 > 2.
    func testDoubleDigitSegmentComparesNumerically() {
        XCTAssertTrue(update("1.2.0", "1.10.0"))
        XCTAssertFalse(update("1.10.0", "1.2.0"))
    }

    func testLeadingVPrefixIsIgnored() {
        XCTAssertTrue(update("v1.0.0", "v1.0.1"))
        XCTAssertFalse(update("v1.0.1", "1.0.1"))
    }

    /// Missing trailing segments are treated as 0, so "1.2" == "1.2.0".
    func testMissingTrailingSegmentTreatedAsZero() {
        XCTAssertFalse(update("1.2", "1.2.0"))
        XCTAssertFalse(update("1.2.0", "1.2"))
        XCTAssertTrue(update("1.2", "1.2.1"))
    }

    /// Regression for issue #7: a pre-release suffix must not drop the segment.
    /// "1.2.0-beta" must parse to [1, 2, 0], not [1, 2].
    func testPreReleaseSuffixDoesNotShiftSegments() {
        // Equal numeric cores compare equal (no update).
        XCTAssertFalse(update("1.2.0-beta", "1.2.0"))
        XCTAssertFalse(update("1.2.0", "1.2.0-beta"))
        // The suffix doesn't corrupt a genuine version bump.
        XCTAssertTrue(update("1.2.0-beta", "1.3.0"))
    }

    func testMajorVersionBump() {
        XCTAssertTrue(update("1.9.9", "2.0.0"))
        XCTAssertFalse(update("2.0.0", "1.9.9"))
    }
}
