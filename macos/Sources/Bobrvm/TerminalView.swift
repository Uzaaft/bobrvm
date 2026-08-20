import AppKit
import Combine
import CoreText
import SwiftUI

/// Draws a `TerminalFrame` with CoreText.
///
/// The view owns its `TerminalEmulator` and subscribes to the console byte
/// stream directly, so guest output becomes terminal state without a pty, a
/// temporary file, or a helper process in between.
///
/// Rendering is a full redraw of the viewport. libghostty-vt tracks per-row
/// dirty state, but a console viewport is a few thousand cells and AppKit
/// coalesces invalidations within a run loop turn, so the bookkeeping to draw
/// less would not pay for itself.
final class TerminalView: NSView {
    private let emulator: TerminalEmulator
    private let metrics: Metrics
    private var cancellable: AnyCancellable?
    private var scrollRowsPending: CGFloat = 0
    private var scaleApplied: CGFloat = 0

    private static let fontSizePoints: CGFloat = 12

    /// Thickness of underlines, strikethroughs, and bar cursors.
    private static let rulePoints: CGFloat = 1

    init(initialOutput: Data, events: AnyPublisher<ConsoleEvent, Never>) {
        self.metrics = Metrics(fontSizePoints: Self.fontSizePoints)
        self.emulator = TerminalEmulator(cols: 80, rows: 24)
        super.init(frame: .zero)

        emulator.write(initialOutput)
        cancellable = events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.apply(event)
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        resizeGrid()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeGrid()
    }

    override func scrollWheel(with event: NSEvent) {
        // Precise deltas are in points; legacy wheels already report lines.
        let rows =
            event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / metrics.cellHeight
            : event.scrollingDeltaY
        scrollRowsPending += rows

        let whole = scrollRowsPending.rounded(.towardZero)
        guard whole != 0 else { return }
        scrollRowsPending -= whole

        // A positive delta means the content moves down, which walks back into
        // scrollback; libghostty-vt counts that direction as negative.
        emulator.scroll(rows: -Int(whole))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = emulator.frame()

        context.setFillColor(Self.cgColor(frame.background))
        context.fill(bounds)

        for (row, runs) in frame.rowRuns.enumerated() {
            let top = CGFloat(row) * metrics.cellHeight
            guard top < bounds.height else { break }
            for run in runs where run.background != nil {
                context.setFillColor(Self.cgColor(run.background!))
                context.fill(rect(column: run.column, columns: run.columns, top: top))
            }
        }

        // A flipped view puts the CTM's y axis the opposite way round from the
        // one glyph outlines are defined in; the text matrix cancels that out.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for (row, runs) in frame.rowRuns.enumerated() {
            let top = CGFloat(row) * metrics.cellHeight
            guard top < bounds.height else { break }
            for run in runs {
                draw(run: run, top: top, in: context)
            }
        }

        if let cursor = frame.cursor {
            draw(cursor: cursor, foreground: frame.foreground, in: context)
        }
    }

    private func apply(_ event: ConsoleEvent) {
        switch event {
        case .output(let data):
            emulator.write(data)
        case .clear:
            emulator.reset()
        }
        needsDisplay = true
    }

    private func resizeGrid() {
        let cols = Int(floor(bounds.width / metrics.cellWidth))
        let rows = Int(floor(bounds.height / metrics.cellHeight))
        let scale = window?.backingScaleFactor ?? 1
        guard cols != emulator.cols || rows != emulator.rows || scale != scaleApplied else {
            return
        }

        scaleApplied = scale
        emulator.resize(
            cols: cols,
            rows: rows,
            cellWidthPx: Int((metrics.cellWidth * scale).rounded()),
            cellHeightPx: Int((metrics.cellHeight * scale).rounded())
        )
        needsDisplay = true
    }

    private func rect(column: Int, columns: Int, top: CGFloat) -> CGRect {
        CGRect(
            x: CGFloat(column) * metrics.cellWidth,
            y: top,
            width: CGFloat(columns) * metrics.cellWidth,
            height: metrics.cellHeight
        )
    }

    private func draw(run: TerminalFrame.Run, top: CGFloat, in context: CGContext) {
        let x = CGFloat(run.column) * metrics.cellWidth

        if !run.text.isEmpty {
            let color = Self.cgColor(
                run.foreground,
                alpha: run.attributes.contains(.faint) ? 0.6 : 1
            )
            let attributed = NSAttributedString(
                string: run.text,
                attributes: [
                    .font: metrics.font(for: run.attributes),
                    .foregroundColor: color,
                    // Ligatures would merge glyphs across cell boundaries.
                    .ligature: 0,
                ]
            )
            context.textPosition = CGPoint(x: x, y: top + metrics.ascent)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }

        let width = CGFloat(run.columns) * metrics.cellWidth
        if run.attributes.contains(.underline) {
            context.setFillColor(Self.cgColor(run.foreground))
            context.fill(
                CGRect(
                    x: x,
                    y: top + metrics.underlinePosition,
                    width: width,
                    height: Self.rulePoints
                ))
        }
        if run.attributes.contains(.strikethrough) {
            context.setFillColor(Self.cgColor(run.foreground))
            context.fill(
                CGRect(
                    x: x,
                    y: top + metrics.ascent * 0.65,
                    width: width,
                    height: Self.rulePoints
                ))
        }
    }

    private func draw(
        cursor: TerminalFrame.Cursor,
        foreground: TerminalColor,
        in context: CGContext
    ) {
        let cell = rect(column: cursor.column, columns: 1, top: CGFloat(cursor.row) * metrics.cellHeight)
        guard cell.minY < bounds.height else { return }

        context.setFillColor(Self.cgColor(foreground, alpha: 0.7))
        switch cursor.style {
        case .block:
            context.fill(cell)
        case .blockHollow:
            context.setStrokeColor(Self.cgColor(foreground, alpha: 0.7))
            context.setLineWidth(Self.rulePoints)
            context.stroke(cell.insetBy(dx: Self.rulePoints / 2, dy: Self.rulePoints / 2))
        case .bar:
            context.fill(CGRect(x: cell.minX, y: cell.minY, width: Self.rulePoints * 2, height: cell.height))
        case .underline:
            context.fill(
                CGRect(
                    x: cell.minX,
                    y: cell.maxY - Self.rulePoints * 2,
                    width: cell.width,
                    height: Self.rulePoints * 2
                ))
        }
    }

    private static func cgColor(_ color: TerminalColor, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: alpha
        )
    }

    /// Cell geometry and the four font faces a terminal cell can ask for.
    ///
    /// The cell is the font's own advance and line height, not a rounded version
    /// of them. Rounding up would make every drawn run creep left of the grid
    /// that background fills and the cursor use, and would open hairlines
    /// between the box-drawing glyphs a console uses to draw tables. Taking the
    /// font's metrics verbatim keeps text, fills, and box drawing on one grid at
    /// the cost of cell edges that can land between pixels.
    ///
    /// Glyphs the face does not have are served by a fallback font whose advance
    /// need not be a whole number of cells. `TerminalFrame` keeps those cells in
    /// runs of their own so such a glyph can overhang its neighbour but cannot
    /// push the rest of the row out of the grid.
    private struct Metrics {
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let ascent: CGFloat
        let underlinePosition: CGFloat

        private let regular: NSFont
        private let bold: NSFont
        private let italic: NSFont
        private let boldItalic: NSFont

        init(fontSizePoints: CGFloat) {
            let regular = NSFont.monospacedSystemFont(ofSize: fontSizePoints, weight: .regular)
            let bold = NSFont.monospacedSystemFont(ofSize: fontSizePoints, weight: .bold)
            let manager = NSFontManager.shared
            self.regular = regular
            self.bold = bold
            self.italic = manager.convert(regular, toHaveTrait: .italicFontMask)
            self.boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)

            let ctFont = regular as CTFont
            var character: UniChar = 0x4D  // "M"
            var glyph = CGGlyph()
            var advance = CGSize.zero
            if CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) {
                CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
            }

            let ascent = CTFontGetAscent(ctFont)
            let descent = CTFontGetDescent(ctFont)
            let leading = CTFontGetLeading(ctFont)
            self.cellWidth = max(1, advance.width)
            self.cellHeight = max(1, ascent + descent + leading)
            self.ascent = ascent
            self.underlinePosition = min(
                self.cellHeight - TerminalView.rulePoints,
                ascent + descent * 0.5
            )
        }

        func font(for attributes: TerminalFrame.Attributes) -> NSFont {
            switch (attributes.contains(.bold), attributes.contains(.italic)) {
            case (true, true): return boldItalic
            case (true, false): return bold
            case (false, true): return italic
            case (false, false): return regular
            }
        }
    }
}

struct TerminalConsoleView: NSViewRepresentable {
    let initialOutput: Data
    let events: AnyPublisher<ConsoleEvent, Never>

    func makeNSView(context: Context) -> TerminalView {
        TerminalView(initialOutput: initialOutput, events: events)
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        _ = nsView
        _ = context
    }
}
