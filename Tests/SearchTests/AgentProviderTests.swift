import XCTest
@testable import Search

/// The provider list's rules, as tabsh's web app states them: a name that
/// isn't blank and isn't another provider's, and no cap past a dozen.
final class AgentProviderTests: XCTestCase {
    private let claude = AgentProvider(name: "Claude Code",
                                       command: "claude {prompt}",
                                       resume: "claude --resume {session}",
                                       acp: "npx --yes @agentclientprotocol/claude-agent-acp")
    private let codex = AgentProvider(name: "Codex", command: "codex {prompt}")

    func testAProviderNeedsAName() {
        XCTAssertEqual(AgentProviderStore.nameTrouble("", in: [claude, codex], except: nil),
                       "A provider needs a name")
    }

    func testAnotherProviderCannotWearTheName() {
        XCTAssertEqual(AgentProviderStore.nameTrouble("Codex", in: [claude, codex], except: nil),
                       "Another provider has that name")
    }

    func testAProviderKeepsItsOwnName() {
        XCTAssertNil(AgentProviderStore.nameTrouble("Codex", in: [claude, codex], except: codex.id))
    }

    func testANewNameIsFine() {
        XCTAssertNil(AgentProviderStore.nameTrouble("Aider", in: [claude, codex], except: nil))
    }

    func testTheStockProviderCarriesTheClaudeCommands() {
        let stock = AgentProviderStore.stock()
        XCTAssertEqual(stock.name, "Claude Code")
        XCTAssertEqual(stock.command, "claude {prompt}")
        XCTAssertEqual(stock.resume, "claude --resume {session}")
        XCTAssertEqual(stock.acp, "npx --yes @agentclientprotocol/claude-agent-acp")
    }

    func testTheWebAppCapIsADozen() {
        XCTAssertEqual(AgentProviderStore.most, 12)
    }

    /// The defaults a fresh daemon offers: the CLIs a New Agent card can
    /// start before anyone has saved a list of their own.
    func testTheStockProvidersOfferTheDefaultAgents() {
        let names = Tabsh.stockProviders.map(\.name)
        XCTAssertTrue(names.contains("Cursor CLI"), "stock providers: \(names)")
        XCTAssertTrue(names.contains("OpenCode"), "stock providers: \(names)")

        let grok = Tabsh.stockProviders.first { $0.name == "Grok" }
        XCTAssertEqual(grok?.command, "grok {prompt}")
        XCTAssertEqual(grok?.resume, "grok --resume {session}")
        XCTAssertEqual(grok?.acp, "grok agent stdio")
    }
}
