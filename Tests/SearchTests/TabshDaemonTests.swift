import XCTest
@testable import Search

final class TabshDaemonTests: XCTestCase {
    func testDaemonPathFindsAgentsInstalledOutsideLaunchd() {
        // Opened from the Dock, the app is given launchd's own PATH, which has
        // none of these; the daemon would then fail to spawn every agent.
        let folders = TabshDaemon.daemonPath.split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            XCTAssertTrue(folders.contains(folder), "\(folder) is not on the daemon's PATH")
        }
    }

    func testDaemonPathKeepsTheAppOwnTabshFirst() {
        let folders = TabshDaemon.daemonPath.split(separator: ":").map(String.init)
        XCTAssertEqual(folders.first, TabshDaemon.binFolder.path)
    }

    func testDaemonPathKeepsTheMacsOwnApartFromTheApp() {
        let folders = TabshDaemon.daemonPath.split(separator: ":").map(String.init)
        XCTAssertTrue(folders.contains("/usr/bin"))
        XCTAssertTrue(folders.contains("/bin"))
    }

    func testDaemonPathHasNoRepeats() {
        let folders = TabshDaemon.daemonPath.split(separator: ":").map(String.init)
        XCTAssertEqual(folders.count, Set(folders).count)
    }
}
