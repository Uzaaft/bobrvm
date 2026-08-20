import Foundation
import GhosttyVt

/// An immutable snapshot of the terminal viewport.
///
/// Rows are lists of style runs rather than lists of cells: consecutive cells
/// that agree on color and attributes draw as one CoreText line, which keeps a
/// console row down to a handful of draw calls even though the guest writes it
/// one cell at a time.
///
/// `columns` is the run's width in cells and is authoritative for background
/// fills and hit testing. It can exceed the glyph count in `text` because a
/// wide character occupies two cells.
struct TerminalFrame {
    var cols: Int
    var rows: Int
    var background: TerminalColor
    var foreground: TerminalColor
    var rowRuns: [[Run]]
    var cursor: Cursor?

    struct Attributes: OptionSet {
        let rawValue: UInt8

        static let bold = Attributes(rawValue: 1 << 0)
        static let italic = Attributes(rawValue: 1 << 1)
        static let faint = Attributes(rawValue: 1 << 2)
        static let underline = Attributes(rawValue: 1 << 3)
        static let strikethrough = Attributes(rawValue: 1 << 4)
    }

    struct Run {
        var column: Int
        var columns: Int
        var text: String
        var foreground: TerminalColor
        var background: TerminalColor?
        var attributes: Attributes
    }

    struct Cursor {
        var column: Int
        var row: Int
        var style: Style

        enum Style {
            case bar
            case block
            case blockHollow
            case underline
        }
    }

    static func empty(background: TerminalColor, foreground: TerminalColor) -> TerminalFrame {
        TerminalFrame(
            cols: 0,
            rows: 0,
            background: background,
            foreground: foreground,
            rowRuns: [],
            cursor: nil
        )
    }
}

struct TerminalColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ rgb: GhosttyColorRgb) {
        self.init(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    var ghostty: GhosttyColorRgb {
        GhosttyColorRgb(r: r, g: g, b: b)
    }
}

/// Bobrvm's owner of the libghostty-vt terminal.
///
/// libghostty-vt's C API is documented as unstable, so every call into it lives
/// in this file: guest bytes go in through `write(_:)` and the renderer reads
/// back plain Swift values through `frame()`.
///
/// The terminal is output-only. No `write_pty` callback is installed, so device
/// queries the guest emits are parsed and discarded rather than answered; the
/// guest console is a log, not an interactive session.
///
/// Not thread-safe. Console events, writes, and drawing all happen on the main
/// thread.
final class TerminalEmulator {
    private(set) var cols: Int
    private(set) var rows: Int

    private let terminal: GhosttyTerminal
    private let renderState: GhosttyRenderState
    private var rowIterator: GhosttyRenderStateRowIterator
    private var rowCells: GhosttyRenderStateRowCells
    private var utf8Scratch: [UInt8]

    /// Ghostty's default palette, so the console looks like a terminal rather
    /// than inheriting whatever libghostty-vt happens to default to.
    static let defaultBackground = TerminalColor(r: 0x28, g: 0x2C, b: 0x34)
    static let defaultForeground = TerminalColor(r: 0xFF, g: 0xFF, b: 0xFF)

    /// A guest console exists to show boot logs, so retain enough history to
    /// hold one. libghostty prunes at page granularity, so the effective limit
    /// is somewhat higher than this.
    private static let scrollbackLinesMax = 10_000

    /// Grapheme clusters are bounded well below this; a cluster that does not
    /// fit is dropped rather than growing the scratch buffer mid-frame.
    private static let utf8ScratchBytes = 128

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.utf8Scratch = [UInt8](repeating: 0, count: Self.utf8ScratchBytes)

        var terminal: GhosttyTerminal?
        let terminalResult = ghostty_terminal_new(
            nil,
            &terminal,
            UInt16(self.cols),
            UInt16(self.rows)
        )
        guard terminalResult == GHOSTTY_SUCCESS, let terminal else {
            preconditionFailure("ghostty_terminal_new failed: \(terminalResult)")
        }
        self.terminal = terminal

        var renderState: GhosttyRenderState?
        let stateResult = ghostty_render_state_new(nil, &renderState)
        guard stateResult == GHOSTTY_SUCCESS, let renderState else {
            preconditionFailure("ghostty_render_state_new failed: \(stateResult)")
        }
        self.renderState = renderState

        // The iterator and cell cursor are allocated once and rebound to the
        // current frame by the render state on every query.
        var iterator: GhosttyRenderStateRowIterator?
        let iteratorResult = ghostty_render_state_row_iterator_new(nil, &iterator)
        guard iteratorResult == GHOSTTY_SUCCESS, let iterator else {
            preconditionFailure("ghostty_render_state_row_iterator_new failed: \(iteratorResult)")
        }
        self.rowIterator = iterator

        var cells: GhosttyRenderStateRowCells?
        let cellsResult = ghostty_render_state_row_cells_new(nil, &cells)
        guard cellsResult == GHOSTTY_SUCCESS, let cells else {
            preconditionFailure("ghostty_render_state_row_cells_new failed: \(cellsResult)")
        }
        self.rowCells = cells

        var scrollbackLines = Self.scrollbackLinesMax
        _ = ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            &scrollbackLines
        )

        var background = Self.defaultBackground.ghostty
        var foreground = Self.defaultForeground.ghostty
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    /// Feed guest bytes through the VT parser.
    ///
    /// This never fails: malformed input is the normal case for a console
    /// attached to an untrusted guest, and libghostty-vt is responsible for
    /// keeping its own state consistent.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_terminal_vt_write(
                terminal,
                base.assumingMemoryBound(to: UInt8.self),
                raw.count
            )
        }
    }

    /// Resize the grid. Cell pixel dimensions are reported to the guest through
    /// in-band size reports and image protocols, so they are passed through even
    /// when the cell count is unchanged.
    func resize(cols: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) {
        let cols = max(1, cols)
        let rows = max(1, rows)
        _ = ghostty_terminal_resize(
            terminal,
            UInt16(clamping: cols),
            UInt16(clamping: rows),
            UInt32(clamping: cellWidthPx),
            UInt32(clamping: cellHeightPx)
        )
        self.cols = cols
        self.rows = rows
    }

    /// Scroll the viewport by whole rows. Negative scrolls toward scrollback.
    func scroll(rows delta: Int) {
        guard delta != 0 else { return }
        ghostty_terminal_scroll_viewport(
            terminal,
            GhosttyTerminalScrollViewport(
                tag: GHOSTTY_SCROLL_VIEWPORT_DELTA,
                value: .init(delta: delta)
            )
        )
    }

    func scrollToBottom() {
        ghostty_terminal_scroll_viewport(
            terminal,
            GhosttyTerminalScrollViewport(tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM, value: .init(delta: 0))
        )
    }

    /// Full reset (RIS). Clears the screen, the scrollback, and any mode the
    /// guest left set, which is what "clear console" should mean.
    func reset() {
        ghostty_terminal_reset(terminal)
    }

    /// Snapshot the viewport for rendering.
    func frame() -> TerminalFrame {
        var frame = TerminalFrame.empty(
            background: Self.defaultBackground,
            foreground: Self.defaultForeground
        )

        guard ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS else {
            return frame
        }

        var cols: UInt16 = 0
        var rows: UInt16 = 0
        var background = GhosttyColorRgb()
        var foreground = GhosttyColorRgb()
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        _ = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND,
            &background
        )
        _ = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND,
            &foreground
        )

        frame.cols = Int(cols)
        frame.rows = Int(rows)
        frame.background = TerminalColor(background)
        frame.foreground = TerminalColor(foreground)
        frame.cursor = cursor()

        var iterator: GhosttyRenderStateRowIterator? = rowIterator
        guard
            ghostty_render_state_get(
                renderState,
                GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                &iterator
            ) == GHOSTTY_SUCCESS,
            let iterator
        else {
            return frame
        }
        rowIterator = iterator

        frame.rowRuns.reserveCapacity(frame.rows)
        while ghostty_render_state_row_iterator_next(iterator) {
            frame.rowRuns.append(
                runs(
                    iterator: iterator,
                    foreground: frame.foreground,
                    background: frame.background
                ))
        }

        return frame
    }

    private func cursor() -> TerminalFrame.Cursor? {
        var visible = false
        var inViewport = false
        _ = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
            &visible
        )
        _ = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &inViewport
        )
        guard visible, inViewport else { return nil }

        var x: UInt16 = 0
        var y: UInt16 = 0
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
        _ = ghostty_render_state_get(
            renderState,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
            &style
        )

        let cursorStyle: TerminalFrame.Cursor.Style
        switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: cursorStyle = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: cursorStyle = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: cursorStyle = .blockHollow
        default: cursorStyle = .block
        }
        return TerminalFrame.Cursor(column: Int(x), row: Int(y), style: cursorStyle)
    }

    private func runs(
        iterator: GhosttyRenderStateRowIterator,
        foreground defaultForeground: TerminalColor,
        background defaultBackground: TerminalColor
    ) -> [TerminalFrame.Run] {
        var cells: GhosttyRenderStateRowCells? = rowCells
        guard
            ghostty_render_state_row_get(
                iterator,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &cells
            ) == GHOSTTY_SUCCESS,
            let cells
        else {
            return []
        }
        rowCells = cells

        var runs: [TerminalFrame.Run] = []
        var current: TerminalFrame.Run?
        var currentIsASCII = true
        var column = 0

        while ghostty_render_state_row_cells_next(cells) {
            let cell = read(
                cells: cells,
                defaultForeground: defaultForeground,
                defaultBackground: defaultBackground
            )

            // The tail half of a wide character carries no glyph of its own:
            // the preceding cell's glyph already spans it, so widen that run
            // rather than emitting a cell that would shift the row right.
            if cell.isSpacerTail {
                current?.columns += 1
                column += 1
                continue
            }

            // Empty cells contribute a space so that columns after them stay
            // aligned; runs are trimmed on close so a row of trailing blanks
            // costs nothing to draw.
            let text = cell.text.isEmpty ? " " : cell.text

            // A run is drawn as one line of text, advancing by the font's own
            // metrics. That only tracks the cell grid while every glyph comes
            // from the monospaced face, so anything outside ASCII is kept in a
            // run of its own: it may overhang its cell, but it cannot drag the
            // rest of the row along with it.
            let isASCII = cell.text.utf8.allSatisfy { $0 < 0x80 }

            if var run = current,
                currentIsASCII,
                isASCII,
                run.column + run.columns == column,
                run.foreground == cell.foreground,
                run.background == cell.background,
                run.attributes == cell.attributes
            {
                run.text += text
                run.columns += 1
                current = run
                column += 1
                continue
            }

            if let run = current, let closed = Self.close(run) {
                runs.append(closed)
            }
            current = TerminalFrame.Run(
                column: column,
                columns: 1,
                text: text,
                foreground: cell.foreground,
                background: cell.background,
                attributes: cell.attributes
            )
            currentIsASCII = isASCII
            column += 1
        }

        if let run = current, let closed = Self.close(run) {
            runs.append(closed)
        }
        return runs
    }

    /// Drop the padding an unstyled run accumulated over empty cells. A run
    /// that has a background or a rule still needs its full width, so it is
    /// left alone.
    private static func close(_ run: TerminalFrame.Run) -> TerminalFrame.Run? {
        guard run.background == nil,
            run.attributes.isDisjoint(with: [.underline, .strikethrough])
        else {
            return run
        }

        // Each trailing space stands for exactly one empty cell, so the width
        // has to shrink with the text or the run would claim the whole row.
        var run = run
        while run.text.last == " ", run.columns > 0 {
            run.text.removeLast()
            run.columns -= 1
        }
        return run.text.isEmpty ? nil : run
    }

    private struct Cell {
        var text: String
        var foreground: TerminalColor
        var background: TerminalColor?
        var attributes: TerminalFrame.Attributes
        var isSpacerTail: Bool
    }

    private func read(
        cells: GhosttyRenderStateRowCells,
        defaultForeground: TerminalColor,
        defaultBackground: TerminalColor
    ) -> Cell {
        var wide = GHOSTTY_CELL_WIDE_NARROW
        var raw: GhosttyCell = 0
        if ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
            &raw
        ) == GHOSTTY_SUCCESS {
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        }
        if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL {
            return Cell(
                text: "",
                foreground: defaultForeground,
                background: nil,
                attributes: [],
                isSpacerTail: true
            )
        }

        var attributes: TerminalFrame.Attributes = []
        var inverse = false
        var invisible = false
        var hasStyling = false
        _ = ghostty_render_state_row_cells_get(
            cells,
            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING,
            &hasStyling
        )
        if hasStyling {
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            if ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                &style
            ) == GHOSTTY_SUCCESS {
                if style.bold { attributes.insert(.bold) }
                if style.italic { attributes.insert(.italic) }
                if style.faint { attributes.insert(.faint) }
                if style.strikethrough { attributes.insert(.strikethrough) }
                if style.underline != GHOSTTY_SGR_UNDERLINE_NONE.rawValue {
                    attributes.insert(.underline)
                }
                inverse = style.inverse
                invisible = style.invisible
            }
        }

        // The render state flattens palette indices and content-tag colors, so
        // a missing color here means "use the terminal default".
        var cellForeground = GhosttyColorRgb()
        var cellBackground = GhosttyColorRgb()
        var foreground: TerminalColor? =
            ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                &cellForeground
            ) == GHOSTTY_SUCCESS ? TerminalColor(cellForeground) : nil
        var background: TerminalColor? =
            ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                &cellBackground
            ) == GHOSTTY_SUCCESS ? TerminalColor(cellBackground) : nil

        // Inverse has to be resolved here rather than at draw time: swapping
        // the pair turns both implicit defaults into explicit colors, and the
        // new background can no longer be left for the renderer to skip.
        if inverse {
            let swapped = foreground ?? defaultForeground
            foreground = background ?? defaultBackground
            background = swapped
        }

        var text = ""
        if !invisible {
            var graphemeLen: UInt32 = 0
            _ = ghostty_render_state_row_cells_get(
                cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                &graphemeLen
            )
            if graphemeLen > 0 { text = utf8(cells: cells) ?? "" }
        }

        return Cell(
            text: text,
            foreground: foreground ?? defaultForeground,
            background: background,
            attributes: attributes,
            isSpacerTail: false
        )
    }

    private func utf8(cells: GhosttyRenderStateRowCells) -> String? {
        utf8Scratch.withUnsafeMutableBufferPointer { scratch in
            guard let base = scratch.baseAddress else { return nil }
            var buffer = GhosttyBuffer(ptr: base, cap: scratch.count, len: 0)
            guard
                ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                    &buffer
                ) == GHOSTTY_SUCCESS,
                buffer.len > 0
            else {
                return nil
            }
            return String(
                decoding: UnsafeBufferPointer(start: base, count: buffer.len),
                as: UTF8.self
            )
        }
    }
}
