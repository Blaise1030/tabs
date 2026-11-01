import XCTest
@testable import Search

final class TabshDropTests: XCTestCase {
    func testShellQuoteLeavesSafePathsAlone() {
        XCTAssertEqual(TabshDrop.shellQuote("/tmp/shot.png"), "/tmp/shot.png")
        XCTAssertEqual(TabshDrop.shellQuote("readme"), "readme")
    }

    func testShellQuoteWrapsSpacesAndQuotes() {
        XCTAssertEqual(TabshDrop.shellQuote("/Users/me/My Photo.png"),
                       "'/Users/me/My Photo.png'")
        XCTAssertEqual(TabshDrop.shellQuote("/tmp/it's.png"),
                       "'/tmp/it'\\''s.png'")
    }

    func testPastePathsJoinsQuotedPathsWithATrailingSpace() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.png"),
            URL(fileURLWithPath: "/tmp/My File.png"),
        ]
        XCTAssertEqual(TabshDrop.pastePaths(urls),
                       "/tmp/a.png '/tmp/My File.png' ")
    }

    func testIsImageRecognisesCommonExtensions() {
        XCTAssertTrue(TabshDrop.isImage(URL(fileURLWithPath: "/x/y.PNG")))
        XCTAssertTrue(TabshDrop.isImage(URL(fileURLWithPath: "/x/y.webp")))
        XCTAssertFalse(TabshDrop.isImage(URL(fileURLWithPath: "/x/y.swift")))
    }
}
