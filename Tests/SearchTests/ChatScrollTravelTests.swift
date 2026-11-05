import AppKit
import XCTest
@testable import Search

/// The transcript's follow while the agent streams: a token grows the list
/// under a pinned viewport, while a reader going back up the conversation
/// moves the scroll view's own offset. The marker at the bottom cannot tell
/// them apart, so ChatScrollTravel reads the offset instead.
final class ChatScrollTravelTests: XCTestCase {
    private let viewport = NSSize(width: 320, height: 500)

    func testGrowthAtTheBottomIsNotAScroll() {
        var travel = ChatScrollTravel()
        XCTAssertFalse(travel.moved(to: 900, in: viewport), "the first sighting only sets the place")
        // Streaming appends rows below: the clip stays exactly where it was.
        XCTAssertFalse(travel.moved(to: 900, in: viewport))
        XCTAssertFalse(travel.moved(to: 900, in: viewport))
    }

    func testScrollingUpTakesTheListFromTheAgent() {
        var travel = ChatScrollTravel()
        XCTAssertFalse(travel.moved(to: 900, in: viewport))
        XCTAssertTrue(travel.moved(to: 870, in: viewport), "the content slid down: the reader went up")
    }

    func testASlowTrackpadScrollAddsUp() {
        var travel = ChatScrollTravel()
        XCTAssertFalse(travel.moved(to: 900, in: viewport))
        XCTAssertFalse(travel.moved(to: 899.7, in: viewport), "less than half a point")
        XCTAssertTrue(travel.moved(to: 899.4, in: viewport), "a point and a bit together, up")
    }

    func testComingBackDownDoesNotCountTheOldRun() {
        var travel = ChatScrollTravel()
        XCTAssertFalse(travel.moved(to: 900, in: viewport))
        XCTAssertTrue(travel.moved(to: 880, in: viewport))
        XCTAssertFalse(travel.moved(to: 885, in: viewport), "scrolling down is not the reader taking the list")
        XCTAssertFalse(travel.moved(to: 884.8, in: viewport), "a quarter of a point up")
        XCTAssertTrue(travel.moved(to: 884.4, in: viewport), "the reader started up again")
    }

    func testAResizeIsNotAScroll() {
        var travel = ChatScrollTravel()
        XCTAssertFalse(travel.moved(to: 900, in: viewport))
        XCTAssertFalse(travel.moved(to: 880, in: NSSize(width: 320, height: 400)),
                       "a narrower pane reflows the words; that is not the reader")
        XCTAssertTrue(travel.moved(to: 879, in: NSSize(width: 320, height: 400)))
    }
}
