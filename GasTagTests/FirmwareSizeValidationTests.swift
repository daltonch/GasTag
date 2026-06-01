import XCTest
@testable import GasTag

/// Tests for the firmware download size check (issue #6). A truncated download
/// or a 200 error-page must not be accepted as valid firmware.
final class FirmwareSizeValidationTests: XCTestCase {

    func testMatchingSizePasses() {
        XCTAssertNoThrow(try GitHubReleaseService.validateDownloadedSize(2048, expected: 2048))
    }

    func testZeroBytesThrows() {
        XCTAssertThrowsError(try GitHubReleaseService.validateDownloadedSize(0, expected: 2048))
    }

    func testTruncatedDownloadThrows() {
        XCTAssertThrowsError(try GitHubReleaseService.validateDownloadedSize(1024, expected: 2048))
    }

    func testLargerThanExpectedThrows() {
        // e.g. an HTML error page that happens to exceed the expected size.
        XCTAssertThrowsError(try GitHubReleaseService.validateDownloadedSize(4096, expected: 2048))
    }

    func testThrownErrorCarriesExpectedAndActual() {
        XCTAssertThrowsError(try GitHubReleaseService.validateDownloadedSize(1024, expected: 2048)) { error in
            guard case GitHubError.firmwareSizeMismatch(let expected, let actual) = error else {
                return XCTFail("Expected firmwareSizeMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 2048)
            XCTAssertEqual(actual, 1024)
        }
    }
}
