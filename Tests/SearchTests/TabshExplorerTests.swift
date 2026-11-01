import XCTest
@testable import Search

final class TabshExplorerTests: XCTestCase {
    func testAFileThatAppearsJoinsTheListing() {
        let paths = TabshTreePaths.applying(add: ["README.md"], remove: [], to: ["src/"])
        XCTAssertEqual(paths, ["README.md", "src/"])
    }

    func testAFolderThatAppearsKeepsItsSlash() {
        let paths = TabshTreePaths.applying(add: ["docs/"], remove: [], to: ["src/"])
        XCTAssertEqual(paths, ["docs/", "src/"])
    }

    func testAFileThatGoesLeavesNothingBehind() {
        let paths = TabshTreePaths.applying(add: [], remove: ["src/main.swift"],
                                            to: ["src/", "src/main.swift", "src/other.swift"])
        XCTAssertEqual(paths, ["src/", "src/other.swift"])
    }

    func testARemovedFolderTakesWhatWasUnderIt() {
        // The watch names a removed folder without the slash its listing
        // entry carried, and nothing below it is mentioned separately.
        let paths = TabshTreePaths.applying(add: [], remove: ["src"],
                                            to: ["README.md", "src/", "src/a/", "src/a/b.swift", "src/c.swift"])
        XCTAssertEqual(paths, ["README.md"])
    }

    func testAChangeAffectsOnlyItsOwnBranch() {
        let paths = TabshTreePaths.applying(add: [], remove: ["src"],
                                            to: ["src/", "src/a.swift", "srcs/b.swift", "other/c.swift"])
        XCTAssertEqual(paths, ["other/c.swift", "srcs/b.swift"])
    }
}
