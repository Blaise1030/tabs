import XCTest
@testable import Search

final class TabshMarkdownTests: XCTestCase {
    private let sample = """
    Sure — here are some common Markdown samples:

    # Heading 1
    ## Heading 2
    ### Heading 3

    **Bold text** and *italic text* and ***both***.

    `Inline code` and a link: [Cursor](https://cursor.com)

    > A blockquote with a short note.

    - Unordered item one
    - Unordered item two
      - Nested item

    1. First ordered step
    2. Second ordered step

    | Column A | Column B |
    | --- | --- |
    | Alpha | Beta |

    ```javascript
    function greet(name: string) {
      return `Hello, ${name}`;
    }
    ```

    ---

    ~~Strikethrough~~ and a task list:
    - [x] Done
    - [ ] Todo
    """

    func testBlocksKeepTheirOwnShape() {
        let blocks = MarkdownParser.parse(sample)
        XCTAssertEqual(blocks.count, 14)

        guard case let .paragraph(intro) = blocks[0] else {
            return XCTFail("the intro should be its own paragraph")
        }
        XCTAssertEqual(intro, "Sure — here are some common Markdown samples:")

        guard case .heading(1, "Heading 1") = blocks[1] else {
            return XCTFail("heading 1 should stand alone")
        }
        guard case .heading(2, "Heading 2") = blocks[2] else {
            return XCTFail("heading 2 should stand alone")
        }
        guard case .heading(3, "Heading 3") = blocks[3] else {
            return XCTFail("heading 3 should stand alone")
        }
    }

    func testListsAndNestingAreSeparate() {
        let blocks = MarkdownParser.parse(sample)

        guard case let .list(unordered) = blocks[7] else {
            return XCTFail("the unordered list should be a list")
        }
        XCTAssertEqual(unordered.map(\.text), ["Unordered item one",
                                               "Unordered item two",
                                               "Nested item"])
        XCTAssertEqual(unordered.map(\.depth), [0, 0, 1])

        guard case let .list(ordered) = blocks[8] else {
            return XCTFail("the ordered list should be its own list")
        }
        XCTAssertEqual(ordered.map(\.number), [1, 2])
        XCTAssertTrue(ordered.allSatisfy(\.ordered))
    }

    func testTableCodeRuleAndTasks() {
        let blocks = MarkdownParser.parse(sample)

        guard case let .table(header, rows) = blocks[9] else {
            return XCTFail("the table should be a table")
        }
        XCTAssertEqual(header, ["Column A", "Column B"])
        XCTAssertEqual(rows, [["Alpha", "Beta"]])

        guard case let .code(code, language) = blocks[10] else {
            return XCTFail("the fenced block should be code")
        }
        XCTAssertEqual(language, "javascript")
        XCTAssertEqual(code, """
        function greet(name: string) {
          return `Hello, ${name}`;
        }
        """)

        guard case .rule = blocks[11] else {
            return XCTFail("the horizontal rule should stand alone")
        }

        guard case let .list(tasks) = blocks[13] else {
            return XCTFail("the task list should be a list")
        }
        XCTAssertEqual(tasks.map(\.checked), [true, false])
        XCTAssertEqual(tasks.map(\.text), ["Done", "Todo"])
    }

    func testParagraphLinesJoinWithinABlock() {
        let blocks = MarkdownParser.parse("one line\nand its continuation\n\nnext")
        guard case let .paragraph(first) = blocks[0] else {
            return XCTFail("the first paragraph should exist")
        }
        XCTAssertEqual(first, "one line and its continuation")
        guard case let .paragraph(second) = blocks[1] else {
            return XCTFail("the second paragraph should exist")
        }
        XCTAssertEqual(second, "next")
    }
}
