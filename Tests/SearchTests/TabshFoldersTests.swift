import XCTest
@testable import Search

final class TabshFoldersTests: XCTestCase {
    func testTildifyWritesHomeAsTilde() {
        XCTAssertEqual(TabshFolders.tildify("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(TabshFolders.tildify("/Users/me/code", home: "/Users/me"), "~/code")
        XCTAssertEqual(TabshFolders.tildify("/tmp", home: "/Users/me"), "/tmp")
    }

    func testExpandHomeReadsTilde() {
        XCTAssertEqual(TabshFolders.expandHome("~", home: "/Users/me"), "/Users/me")
        XCTAssertEqual(TabshFolders.expandHome("~/code", home: "/Users/me"), "/Users/me/code")
        XCTAssertEqual(TabshFolders.expandHome("~bob", home: "/Users/me"), "~bob")
        XCTAssertEqual(TabshFolders.expandHome("/tmp", home: "/Users/me"), "/tmp")
    }

    func testRecentFoldersAreMostRecentlyMovedWithoutRepeats() {
        let sessions = [
            Tabsh.SessionInfo(id: "a", name: "A", status: "in_progress", statusAt: 10,
                              cwd: "/a"),
            Tabsh.SessionInfo(id: "b", name: "B", status: "in_progress", statusAt: 30,
                              cwd: "/b"),
            Tabsh.SessionInfo(id: "c", name: "C", status: "in_progress", statusAt: 20,
                              cwd: "/a"),
            Tabsh.SessionInfo(id: "d", name: "D", status: "in_progress", statusAt: 40,
                              cwd: nil),
        ]
        XCTAssertEqual(TabshFolders.recent(from: sessions, limit: 8), ["/b", "/a"])
        XCTAssertEqual(TabshFolders.recent(from: sessions, limit: 1), ["/b"])
    }

    func testMoveActiveWrapsAround() {
        XCTAssertEqual(TabshFolders.moveActive(-1, by: 1, count: 3), 0)
        XCTAssertEqual(TabshFolders.moveActive(-1, by: -1, count: 3), 2)
        XCTAssertEqual(TabshFolders.moveActive(2, by: 1, count: 3), 0)
        XCTAssertEqual(TabshFolders.moveActive(0, by: -1, count: 3), 2)
        XCTAssertEqual(TabshFolders.moveActive(0, by: 1, count: 0), -1)
    }
}

private extension Tabsh.SessionInfo {
    init(id: String, name: String, status: String, statusAt: Int, cwd: String?) {
        self.init(id: id, name: name, status: status, statusAt: statusAt,
                  note: nil, cwd: cwd, agent: nil, acp: nil, mode: nil,
                  parent: nil, pinned: false)
    }
}
