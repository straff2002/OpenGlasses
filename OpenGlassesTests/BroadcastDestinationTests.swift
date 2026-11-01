import XCTest
@testable import OpenGlasses

final class BroadcastDestinationTests: XCTestCase {
    func testMissingOrWhitespaceOnlySettingsRequireSetup() {
        for (url, key) in [("", ""), ("rtmp://example.com/live", ""),
                           ("", "key"), (" \n", "key"), ("rtmp://example.com/live", "\t\n")] {
            XCTAssertThrowsError(try BroadcastDestination(rtmpURL: url, streamKey: key)) { error in
                guard case BroadcastError.notConfigured = error else {
                    return XCTFail("Missing settings should require setup")
                }
            }
        }
    }

    func testInvalidAddressesAreRejectedBeforeConnecting() {
        for url in ["example.com/live", "https://example.com/live", "rtmp://", "rtmps:///live"] {
            XCTAssertThrowsError(try BroadcastDestination(rtmpURL: url, streamKey: "key")) { error in
                guard case BroadcastError.invalidURL = error else {
                    return XCTFail("Invalid URL should identify the address field")
                }
            }
        }
    }

    func testSupportedDestinationsTrimPastedWhitespace() throws {
        for url in ["rtmp://example.com:1935/live", "rtmps://example.com/app"] {
            let destination = try BroadcastDestination(rtmpURL: " \n\(url)\n", streamKey: " key\n")
            XCTAssertEqual(destination.url, url)
            XCTAssertEqual(destination.streamKey, "key")
        }
    }

    func testConnectionFailureOffersRecoveryWithoutTransportDetails() {
        let message = BroadcastError.connectionFailed.localizedDescription
        XCTAssertTrue(message.contains("internet connection"))
        XCTAssertTrue(message.contains("RTMP URL and stream key"))
        XCTAssertTrue(message.contains("Live Streaming"))
        XCTAssertFalse(message.contains("HaishinKit"))
        XCTAssertFalse(message.contains("error 4"))
    }
}
