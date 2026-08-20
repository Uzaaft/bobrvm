import XCTest

@testable import Bobrvm

/// Covers the translation between libghostty-vt's cell grid and the run-based
/// frames the console renderer draws. The escape sequences here are the ones a
/// guest kernel actually emits, and the assertions pin down the parts of that
/// translation that have no other observer: run coalescing, column alignment
/// across untouched cells, and inverse-video resolution.
final class TerminalEmulatorTests: XCTestCase {
    private func emulator(cols: Int = 20, rows: Int = 4) -> TerminalEmulator {
        TerminalEmulator(cols: cols, rows: rows)
    }

    private func write(_ terminal: TerminalEmulator, _ text: String) {
        terminal.write(Data(text.utf8))
    }

    func testPlainTextBecomesOneRun() {
        let terminal = emulator()
        write(terminal, "Hello")

        let frame = terminal.frame()
        XCTAssertEqual(frame.cols, 20)
        XCTAssertEqual(frame.rowRuns.count, 4)

        let runs = frame.rowRuns[0]
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "Hello")
        XCTAssertEqual(runs[0].column, 0)
        XCTAssertEqual(runs[0].columns, 5)
        XCTAssertEqual(runs[0].foreground, frame.foreground)
        XCTAssertNil(runs[0].background)
        XCTAssertEqual(runs[0].attributes, [])
    }

    func testUntouchedCellsDoNotShiftLaterColumns() {
        let terminal = emulator()
        // CUP to column 5 leaves cells 1 through 3 untouched; the run has to
        // keep them as width so "B" still lands in column 4.
        write(terminal, "A\u{1b}[5GB")

        let runs = terminal.frame().rowRuns[0]
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "A   B")
        XCTAssertEqual(runs[0].columns, 5)
    }

    func testTrailingBlanksAreNotDrawn() {
        let terminal = emulator()
        write(terminal, "hi")

        XCTAssertEqual(terminal.frame().rowRuns[0].count, 1)
        for row in 1..<4 {
            XCTAssertTrue(terminal.frame().rowRuns[row].isEmpty)
        }
    }

    func testDirectColorsSplitRuns() {
        let terminal = emulator()
        write(terminal, "a\u{1b}[38;2;10;20;30m\u{1b}[48;2;1;2;3mb\u{1b}[0mc")

        let runs = terminal.frame().rowRuns[0]
        XCTAssertEqual(runs.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(runs[1].foreground, TerminalColor(r: 10, g: 20, b: 30))
        XCTAssertEqual(runs[1].background, TerminalColor(r: 1, g: 2, b: 3))
        XCTAssertEqual(runs[1].column, 1)
        XCTAssertNil(runs[0].background)
        XCTAssertNil(runs[2].background)
    }

    func testAttributesSurviveTheRoundTrip() {
        let terminal = emulator()
        write(terminal, "\u{1b}[1mb\u{1b}[0m\u{1b}[3mi\u{1b}[0m\u{1b}[4mu\u{1b}[0m\u{1b}[9ms")

        let runs = terminal.frame().rowRuns[0]
        XCTAssertEqual(runs.count, 4)
        XCTAssertEqual(runs[0].attributes, .bold)
        XCTAssertEqual(runs[1].attributes, .italic)
        XCTAssertEqual(runs[2].attributes, .underline)
        XCTAssertEqual(runs[3].attributes, .strikethrough)
    }

    func testInverseResolvesToExplicitColors() {
        let terminal = emulator()
        write(terminal, "\u{1b}[7mx")

        let frame = terminal.frame()
        let run = frame.rowRuns[0][0]
        XCTAssertEqual(run.background, frame.foreground)
        XCTAssertEqual(run.foreground, frame.background)
    }

    func testInvisibleTextKeepsItsBackground() {
        let terminal = emulator()
        write(terminal, "\u{1b}[8;48;2;9;9;9mx")

        let run = terminal.frame().rowRuns[0][0]
        XCTAssertEqual(run.text, " ")
        XCTAssertEqual(run.background, TerminalColor(r: 9, g: 9, b: 9))
    }

    func testWideCharactersClaimTwoColumnsInRunsOfTheirOwn() {
        let terminal = emulator()
        write(terminal, "\u{4E16}\u{754C}!")

        // Each non-ASCII cell is isolated so a fallback glyph's advance cannot
        // drag the rest of the row off the grid.
        let runs = terminal.frame().rowRuns[0]
        XCTAssertEqual(runs.map(\.text), ["\u{4E16}", "\u{754C}", "!"])
        XCTAssertEqual(runs.map(\.column), [0, 2, 4])
        XCTAssertEqual(runs.map(\.columns), [2, 2, 1])
    }

    func testASCIIRunIsNotSplitByStyleAgnosticText() {
        let terminal = emulator()
        write(terminal, "a\u{4E16}b")

        let runs = terminal.frame().rowRuns[0]
        XCTAssertEqual(runs.map(\.text), ["a", "\u{4E16}", "b"])
        XCTAssertEqual(runs.map(\.column), [0, 1, 3])
    }

    func testCursorTracksTheWriteHead() {
        let terminal = emulator()
        write(terminal, "abc\r\nde")

        let cursor = terminal.frame().cursor
        XCTAssertEqual(cursor?.column, 2)
        XCTAssertEqual(cursor?.row, 1)
    }

    func testHiddenCursorIsAbsentFromTheFrame() {
        let terminal = emulator()
        write(terminal, "x\u{1b}[?25l")

        XCTAssertNil(terminal.frame().cursor)
    }

    func testResetClearsTheScreen() {
        let terminal = emulator()
        write(terminal, "noise\r\nmore noise")
        terminal.reset()

        let frame = terminal.frame()
        for runs in frame.rowRuns {
            XCTAssertTrue(runs.isEmpty)
        }
    }

    func testResizeReflowsTheGrid() {
        let terminal = emulator(cols: 10, rows: 2)
        terminal.resize(cols: 40, rows: 6, cellWidthPx: 8, cellHeightPx: 16)

        XCTAssertEqual(terminal.cols, 40)
        XCTAssertEqual(terminal.rows, 6)

        let frame = terminal.frame()
        XCTAssertEqual(frame.cols, 40)
        XCTAssertEqual(frame.rowRuns.count, 6)
    }

    func testScrollbackIsReachableAndReturnable() {
        let terminal = emulator(cols: 10, rows: 2)
        write(terminal, "one\r\ntwo\r\nthree")

        XCTAssertEqual(terminal.frame().rowRuns[0].first?.text, "two")

        terminal.scroll(rows: -1)
        XCTAssertEqual(terminal.frame().rowRuns[0].first?.text, "one")

        terminal.scrollToBottom()
        XCTAssertEqual(terminal.frame().rowRuns[0].first?.text, "two")
    }
}
