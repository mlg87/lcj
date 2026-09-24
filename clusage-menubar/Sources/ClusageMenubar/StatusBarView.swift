/// StatusBarView.swift — Stats-style compact usage display for the macOS menu bar.
///
/// Custom NSView subclass that draws a 2-row grid of usage cells:
///   Left column:  5H gauge (top)    /  RESETS <time> (bottom)
///   Right column: WK gauge  (top)   /  F gauge        (bottom)
///   Codex column: 1D cost · 7D cost (top) / MO gauge · RST date (bottom)
/// Columns are separated by a vertical rule. 7pt labels / 9pt monospaced-digit values.
///
/// Either provider can be hidden (never both — see ClusageCore.ProviderVisibility),
/// and the Codex column additionally stays hidden when no Codex install is
/// detected, so Claude-only users see the original two-column layout unchanged. Claude cells are percent-of-limit gauges; Codex 1D/7D are dollar
/// estimates (or token counts) because Codex plans expose no 5h/weekly windows.
/// The MO cell is a real percent-of-limit gauge when ChatGPT reports a monthly
/// spend control, otherwise a month-to-date $ against the user's budget.
///
/// A second layout, MenuBarStyle.remaining, answers "how much room is left and
/// when do I get more?" directly: two provider blocks (✻ Claude / ✿ Codex), each
/// limit as a draining segmented bar with "N% left · ↻countdown", dollars kept
/// in the dropdown. Neutral bars; amber when capacity is low; red when nearly
/// exhausted — colour means "needs attention", not "how much was consumed".
///
/// A third, MenuBarStyle.centerDash, gives each provider one long track: the
/// weekly limit as a solid fill, the five-hour limit as a dashed overlay, then
/// compact W/H values and a reset countdown.
///
/// Rendering is pure NSColor / NSBezierPath so it adapts automatically to light/dark
/// menu bar appearance (all colors are dynamic NSColor semantics).

import AppKit
import ClusageCore

final class StatusBarView: NSView {

    // MARK: - Layout constants

    /// Full content height (22pt = standard macOS menu bar content area).
    private static let barHeight: CGFloat = 22
    /// Half-spacing between the two row centers: rows sit at midY ± rowOffset.
    private static let rowOffset: CGFloat = 5.5

    // Fonts. Two rows split 22pt, so labels can be larger than the old 3-row stack:
    // 7pt labels / 9pt monospaced-digit values (two-column update 2026-07-11).
    private static let labelFont   = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let timeFont    = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    // Mini progress bar dimensions
    private static let barW: CGFloat = 20
    private static let barH: CGFloat = 4
    private static let barCorner: CGFloat = 2

    // Horizontal gaps inside a row
    private static let labelBarGap: CGFloat = 3   // label column → bar
    private static let barTextGap: CGFloat  = 3   // bar → percent column
    private static let cellGap: CGFloat     = 8   // between label/cell pairs in the Codex block

    // Vertical separator dimensions
    private static let sepW: CGFloat   = 1
    private static let sepH: CGFloat   = 16   // spans both rows
    private static let sepPad: CGFloat = 6

    /// Hardcoded label for the reset-time row (wider than "5H", sets the left label column width).
    private static let resetLabel = "RESETS"

    // MARK: - State

    var snapshot: UsageSnapshot?
    var resetDate: Date?   // session.resetsAt — shown in the bottom-left cell
    var isDegraded = false

    // Codex column state (see CodexScanner / CodexPlanFetcher / CodexDisplayStore)
    var codexSummary: CodexSummary?
    /// true → 1D/7D show estimated dollars; false → compact token counts.
    var codexShowsDollars = true
    /// Green/yellow boundary for the month-to-date barometer (fallback MO cell).
    var codexBudget: Double = CodexBudgetStore.defaultBudget
    /// Monthly spend-control state from ChatGPT; when present the MO cell is a
    /// true percent-of-limit gauge instead of the $-budget barometer.
    var codexPlan: CodexPlanUsage?
    /// Which providers the user wants shown (ProviderVisibilityStore).
    var visibility: ProviderVisibility = .both
    /// Reference "now" for countdown text, set by AppDelegate once per repaint so
    /// measurement and drawing cannot straddle a minute boundary.
    var renderDate = Date()
    /// Which layout to draw (MenuBarStyleStore). AppDelegate repaints every
    /// minute in .remaining and .centerDash so the countdowns stay current.
    var style: MenuBarStyle = .grid

    /// Codex renders when the user wants it AND either it has data or it is the
    /// only provider selected. The data condition keeps Claude-only Macs from
    /// growing a dashed-out third column (codexSummary stays nil when ~/.codex
    /// has no sessions); the "only provider" condition means someone who hid
    /// Claude still sees a Codex block from launch instead of an empty bar that
    /// fills in a second later.
    var showsCodexColumn: Bool {
        guard visibility.codex else { return false }
        return codexSummary != nil || codexPlan != nil || !visibility.claude
    }

    /// Claude renders when the user wants it, and also whenever Codex ends up
    /// drawing nothing — the status item must never be blank, even if Codex is
    /// uninstalled while Claude is hidden.
    var showsClaudeColumn: Bool {
        visibility.claude || !showsCodexColumn
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Opaque = false so the menu bar's translucent background shows through.
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = false
    }

    // MARK: - Hit testing

    /// Return nil so clicks fall through to the status item's button,
    /// which opens the NSMenu. Without this the view swallows the click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Layout measurement

    /// Compute the total drawing width for the current content.
    /// Called externally by AppDelegate to set statusItem.length.
    func preferredWidth() -> CGFloat {
        switch style {
        case .grid:      return gridPreferredWidth()
        case .remaining: return remainingPreferredWidth()
        case .centerDash: return centerDashPreferredWidth()
        }
    }

    private func gridPreferredWidth() -> CGFloat {
        let sepUnit = Self.sepPad + Self.sepW + Self.sepPad
        var w: CGFloat = 4   // 2pt inset on each side
        if showsClaudeColumn {
            let m = gridMetrics()
            w += m.leftColW + sepUnit + m.rightColW
            if showsCodexColumn { w += sepUnit }
        }
        if showsCodexColumn { w += cellGridWidth(codexGridColumns()) }
        return w
    }

    // MARK: - Grid metrics

    private struct GridMetrics {
        let leftLabelW: CGFloat    // max("5H"-entry label, "RESETS") at labelFont
        let rightLabelW: CGFloat   // max(week label, fable label) at labelFont
        let pctW: CGFloat          // max percentText over all 3 entries at percentFont
        let leftColW: CGFloat
        let rightColW: CGFloat
    }

    private func gridMetrics() -> GridMetrics {
        let e = entriesForDisplay()

        let leftLabelW  = max(measured(e.session.label, font: Self.labelFont),
                              measured(Self.resetLabel, font: Self.labelFont))
        let rightLabelW = max(measured(e.week.label, font: Self.labelFont),
                              measured(e.fable.label, font: Self.labelFont))
        let allPctW     = max(measured(e.session.percentText, font: Self.percentFont),
                          max(measured(e.fable.percentText, font: Self.percentFont),
                              measured(e.week.percentText, font: Self.percentFont)))

        func gaugeRowW(_ lw: CGFloat) -> CGFloat {
            lw + Self.labelBarGap + Self.barW + Self.barTextGap + allPctW
        }
        let timeStrW = measured(timeText(), font: Self.timeFont)
        let timeRowW = leftLabelW + Self.labelBarGap + timeStrW

        let leftColW  = max(gaugeRowW(leftLabelW), timeRowW)
        let rightColW = gaugeRowW(rightLabelW)

        return GridMetrics(
            leftLabelW: leftLabelW,
            rightLabelW: rightLabelW,
            pctW: allPctW,
            leftColW: leftColW,
            rightColW: rightColW
        )
    }

    private func measured(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .grid:      drawGrid()
        case .remaining: drawRemaining()
        case .centerDash: drawCenterDash()
        }
    }

    private func drawGrid() {
        let midY = bounds.midY
        let topY = midY + Self.rowOffset
        let botY = midY - Self.rowOffset
        var x: CGFloat = 2

        if showsClaudeColumn {
            let e = entriesForDisplay()
            let m = gridMetrics()
            drawRow(entry: e.session, x: x, centerY: topY, labelW: m.leftLabelW, pctW: m.pctW)
            drawTimeRow(x: x, centerY: botY, labelW: m.leftLabelW)

            x = drawSeparator(x: x + m.leftColW, midY: midY)
            drawRow(entry: e.week,  x: x, centerY: topY, labelW: m.rightLabelW, pctW: m.pctW)
            drawRow(entry: e.fable, x: x, centerY: botY, labelW: m.rightLabelW, pctW: m.pctW)
            x += m.rightColW

            if showsCodexColumn { x = drawSeparator(x: x, midY: midY) }
        }

        if showsCodexColumn {
            drawCellGrid(codexGridColumns(), x: x, topY: topY, botY: botY)
        }
    }

    // MARK: - Row drawing

    private func drawRow(entry: SegmentEntry, x: CGFloat, centerY: CGFloat, labelW: CGFloat, pctW: CGFloat) {
        // -- Label: right-aligned in its column, vertically centered on the row --
        drawRightAlignedLabel(entry.label, x: x, labelW: labelW, centerY: centerY)

        // -- Mini progress bar (track + fill), reusing fillColor(for:) --
        let barX = x + labelW + Self.labelBarGap
        drawMiniBar(percent: entry.percent, color: fillColor(for: entry.percent), x: barX, centerY: centerY)

        // -- Percent: right-aligned in its column so digits line up --
        drawRightAlignedValue(entry.percentText, tint: .labelColor,
                              rightEdge: barX + Self.barW + Self.barTextGap + pctW, centerY: centerY)
    }

    /// Draw the RESETS label and reset-time string in the bottom-left cell.
    private func drawTimeRow(x: CGFloat, centerY: CGFloat, labelW: CGFloat) {
        // "RESETS" — right-aligned in labelW, secondary label color (same style as gauge labels)
        drawRightAlignedLabel(Self.resetLabel, x: x, labelW: labelW, centerY: centerY)

        // Reset time — left-aligned after label gap, primary label color
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.timeFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let tStr  = timeText() as NSString
        let tSize = tStr.size(withAttributes: timeAttrs)
        tStr.draw(at: NSPoint(x: x + labelW + Self.labelBarGap,
                              y: centerY - tSize.height / 2),
                  withAttributes: timeAttrs)
    }

    @discardableResult
    private func drawSeparator(x: CGFloat, midY: CGFloat) -> CGFloat {
        let sepRect = NSRect(
            x: x + Self.sepPad,
            y: midY - Self.sepH / 2,
            width: Self.sepW,
            height: Self.sepH
        )
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: sepRect).fill()
        return x + Self.sepPad + Self.sepW + Self.sepPad
    }

    // MARK: - Drawing primitives (shared by the Claude rows and the Codex block)

    /// 7pt secondary label, right-aligned to x + labelW.
    private func drawRightAlignedLabel(_ label: String, x: CGFloat, labelW: CGFloat, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str  = label as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: x + labelW - size.width, y: centerY - size.height / 2),
                 withAttributes: attrs)
    }

    /// 9pt monospaced-digit value, right-aligned to rightEdge so digits line up.
    private func drawRightAlignedValue(_ value: String, tint: NSColor, rightEdge: CGFloat, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.percentFont,
            .foregroundColor: tint,
        ]
        let str  = value as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: rightEdge - size.width, y: centerY - size.height / 2),
                 withAttributes: attrs)
    }

    /// Horizontal mini gauge (track + fill) starting at x.
    private func drawMiniBar(percent: Int, color: NSColor, x: CGFloat, centerY: CGFloat) {
        let trackRect = NSRect(x: x, y: centerY - Self.barH / 2, width: Self.barW, height: Self.barH)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: Self.barCorner, yRadius: Self.barCorner).fill()
        let fillW = CGFloat(percent) / 100 * Self.barW
        if fillW > 0 {
            let fillRect = NSRect(x: x, y: centerY - Self.barH / 2, width: fillW, height: Self.barH)
            color.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: Self.barCorner, yRadius: Self.barCorner).fill()
        }
    }

    // MARK: - Codex block: a 2-row cell grid
    //
    //   1D $16.2   7D $30.1
    //   MO ▓▓░ 84%  RST 8/31
    //
    // A column = one label + one cell per row. Label widths and content widths
    // are shared across both rows, so labels right-align to a common edge and
    // values right-align so digits line up — the same discipline as the Claude
    // columns, expressed as data so the block can vary (RST only with a real limit).

    /// One cell: a gauge (bar left, value right) or a plain value (right-aligned).
    private enum GridCell {
        case gauge(percent: Int, text: String, color: NSColor)
        case text(String, tint: NSColor)
        case empty
    }

    private struct GridColumn {
        let topLabel: String
        let bottomLabel: String
        let top: GridCell
        let bottom: GridCell
    }

    private func cellContentW(_ cell: GridCell) -> CGFloat {
        switch cell {
        case .gauge(_, let text, _):
            return Self.barW + Self.barTextGap + measured(text, font: Self.percentFont)
        case .text(let value, _):
            return measured(value, font: Self.percentFont)
        case .empty:
            return 0
        }
    }

    private func cellGridMetrics(_ cols: [GridColumn]) -> [(labelW: CGFloat, contentW: CGFloat)] {
        cols.map { col in
            (labelW: max(measured(col.topLabel, font: Self.labelFont),
                         measured(col.bottomLabel, font: Self.labelFont)),
             contentW: max(cellContentW(col.top), cellContentW(col.bottom)))
        }
    }

    private func cellGridWidth(_ cols: [GridColumn]) -> CGFloat {
        let metrics = cellGridMetrics(cols)
        var w: CGFloat = 0
        for (i, m) in metrics.enumerated() {
            w += m.labelW + Self.labelBarGap + m.contentW
            if i < metrics.count - 1 { w += Self.cellGap }
        }
        return w
    }

    private func drawCell(_ cell: GridCell, x: CGFloat, contentW: CGFloat, centerY: CGFloat) {
        switch cell {
        case .gauge(let percent, let text, let color):
            drawMiniBar(percent: percent, color: color, x: x, centerY: centerY)
            drawRightAlignedValue(text, tint: .labelColor, rightEdge: x + contentW, centerY: centerY)
        case .text(let value, let tint):
            drawRightAlignedValue(value, tint: tint, rightEdge: x + contentW, centerY: centerY)
        case .empty:
            break
        }
    }

    /// Draw a cell grid starting at x; returns the x after the grid.
    @discardableResult
    private func drawCellGrid(_ cols: [GridColumn], x: CGFloat, topY: CGFloat, botY: CGFloat) -> CGFloat {
        let metrics = cellGridMetrics(cols)
        var cx = x
        for i in 0..<cols.count {
            let m = metrics[i]
            if case .empty = cols[i].top {} else {
                drawRightAlignedLabel(cols[i].topLabel, x: cx, labelW: m.labelW, centerY: topY)
            }
            if case .empty = cols[i].bottom {} else {
                drawRightAlignedLabel(cols[i].bottomLabel, x: cx, labelW: m.labelW, centerY: botY)
            }
            let contentX = cx + m.labelW + Self.labelBarGap
            drawCell(cols[i].top, x: contentX, contentW: m.contentW, centerY: topY)
            drawCell(cols[i].bottom, x: contentX, contentW: m.contentW, centerY: botY)
            cx = contentX + m.contentW + Self.cellGap
        }
        return cx - Self.cellGap
    }

    /// The Codex 2×2 block: 1D/MO on the left, 7D/RST on the right. RST (the
    /// monthly reset date) only exists when ChatGPT reports a real limit.
    private func codexGridColumns() -> [GridColumn] {
        let c = codexDisplay()
        return [
            GridColumn(topLabel: "1D", bottomLabel: "MO",
                       top: .text(c.day, tint: .labelColor),
                       bottom: .gauge(percent: c.monthPercent, text: c.month, color: c.monthColor)),
            GridColumn(topLabel: "7D", bottomLabel: c.monthReset != nil ? "RST" : "",
                       top: .text(c.week, tint: .labelColor),
                       bottom: c.monthReset.map { .text($0, tint: .labelColor) } ?? .empty),
        ]
    }

    // MARK: - Remaining-capacity style
    //
    //   ✻  5h  ▰▱▱▱▱ 24% left · ↻19m   │  ✿  Mo  ▰▱▱▱▱ 21% left · ↻19d
    //      Wk  ▰▰▰▱▱ 56% left · ↻3d    │
    //
    // One block per provider, marked by an icon spanning both rows. Each row is
    // one limit: label · draining segmented bar · "% left" · reset countdown.
    // The model-scoped weekly limit replaces the all-models one only when it is
    // the tighter of the two (labelled "Wk(F)"). Codex shows the real monthly
    // limit when ChatGPT reports one, otherwise the personal $ budget, labelled
    // "Budget" so it is never mistaken for a provider limit.

    private static let segCount = 5
    private static let segW: CGFloat = 4
    private static let segGap: CGFloat = 1
    private static var segTrackW: CGFloat { CGFloat(segCount) * segW + CGFloat(segCount - 1) * segGap }
    /// Labels carry the meaning of each row, so they get full label colour and
    /// bold weight here (the grid's secondaryLabelColor reads faint on tinted bars).
    private static let remLabelFont = NSFont.systemFont(ofSize: 7, weight: .bold)
    private static let iconFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let claudeIcon = "✻"
    private static let blossomSize: CGFloat = 10
    private static let iconRowGap: CGFloat = 4    // icon → first label

    private struct RemainingRow {
        let label: String
        /// 0–100 fill for the bar; nil draws an empty track ("no data").
        let remaining: Int?
        let text: String
        /// nil → neutral.
        let band: Band?
    }

    private func remainingRow(label: String, bucket: Bucket?, now: Date) -> RemainingRow {
        guard let b = bucket else {
            return RemainingRow(label: label, remaining: nil, text: "– · ↻–", band: nil)
        }
        let left = 100 - b.percent
        return RemainingRow(label: label, remaining: left,
                            text: "\(left)% left · ↻\(menuBarCountdown(to: b.resetsAt, from: now))",
                            band: band(forPercent: b.percent))
    }

    private func claudeRemainingRows(now: Date) -> [RemainingRow] {
        guard !isDegraded, let snap = snapshot else {
            return [remainingRow(label: "5h", bucket: nil, now: now),
                    remainingRow(label: "Wk", bucket: nil, now: now)]
        }
        var rows = [remainingRow(label: "5h", bucket: snap.session, now: now)]
        // Only surface the model-scoped week when it's what will actually stop
        // you first; otherwise the all-models week is the one that matters.
        // Either way the label names which bucket is on screen — a scoped bucket
        // shown as a bare "Wk" would overstate how much of the week is left.
        func scopedLabel(_ b: Bucket) -> String { "Wk(\(menuBarShortLabel(b.label)))" }
        switch (snap.weeklyAll, snap.weeklyScoped) {
        case let (all?, scoped?) where scoped.percent > all.percent:
            rows.append(remainingRow(label: scopedLabel(scoped), bucket: scoped, now: now))
        case let (all?, _):
            rows.append(remainingRow(label: "Wk", bucket: all, now: now))
        case let (nil, scoped?):
            rows.append(remainingRow(label: scopedLabel(scoped), bucket: scoped, now: now))
        case (nil, nil):
            rows.append(remainingRow(label: "Wk", bucket: nil, now: now))
        }
        return rows
    }

    private func codexRemainingRows(now: Date) -> [RemainingRow] {
        if let plan = codexPlan {
            let left = 100 - plan.usedPercent
            return [RemainingRow(label: "Mo", remaining: left,
                                 text: "\(left)% left · ↻\(menuBarCountdown(to: plan.resetsAt, from: now))",
                                 band: band(forPercent: plan.usedPercent))]
        }
        guard let s = codexSummary else {
            return [RemainingRow(label: "Mo", remaining: nil, text: "– · ↻–", band: nil)]
        }
        let mtd = s.monthToDateCost
        let left = 100 - budgetFillPercent(monthCost: mtd, budget: codexBudget)
        let reset = menuBarCountdown(to: startOfNextMonth(after: now), from: now)
        // Past the budget, "0% left" hides how far past; say the overshoot instead.
        let text = mtd > codexBudget
            ? "\(formatCost(mtd - codexBudget)) over · ↻\(reset)"
            : "\(left)% left · ↻\(reset)"
        return [RemainingRow(label: "Budget", remaining: left, text: text,
                             band: budgetBand(monthCost: mtd, budget: codexBudget))]
    }

    private func remainingColor(_ band: Band?) -> NSColor {
        switch band {
        case .ok?, nil:  return NSColor.labelColor.withAlphaComponent(0.55)
        case .warn?:     return .systemOrange
        case .critical?: return .systemRed
        }
    }

    private func iconColumnW() -> CGFloat {
        max(measured(Self.claudeIcon, font: Self.iconFont), Self.blossomSize)
    }

    private func remainingBlockWidth(_ rows: [RemainingRow]) -> CGFloat {
        let labelW = rows.map { measured($0.label, font: Self.remLabelFont) }.max() ?? 0
        let textW  = rows.map { measured($0.text, font: Self.percentFont) }.max() ?? 0
        return iconColumnW() + Self.iconRowGap + labelW + Self.labelBarGap
            + Self.segTrackW + Self.barTextGap + textW
    }

    private func remainingPreferredWidth() -> CGFloat {
        let now = renderDate
        var w: CGFloat = 4   // 2pt inset on each side
        if showsClaudeColumn {
            w += remainingBlockWidth(claudeRemainingRows(now: now))
            if showsCodexColumn { w += Self.sepPad + Self.sepW + Self.sepPad }
        }
        if showsCodexColumn { w += remainingBlockWidth(codexRemainingRows(now: now)) }
        return w
    }

    private func drawRemaining() {
        let now = renderDate
        let midY = bounds.midY
        var x: CGFloat = 2
        if showsClaudeColumn {
            x = drawRemainingBlock(claudeRemainingRows(now: now), x: x, midY: midY) { center in
                self.drawClaudeIcon(center: center)
            }
            if showsCodexColumn { x = drawSeparator(x: x, midY: midY) }
        }
        if showsCodexColumn {
            drawRemainingBlock(codexRemainingRows(now: now), x: x, midY: midY) { center in
                self.drawCodexIcon(center: center)
            }
        }
    }

    /// Icon spanning both rows, then one row per limit; a single row sits on the
    /// centre line so a one-limit block doesn't look half-empty. Returns end x.
    @discardableResult
    private func drawRemainingBlock(_ rows: [RemainingRow], x: CGFloat, midY: CGFloat,
                                    icon: (NSPoint) -> Void) -> CGFloat {
        let iconW = iconColumnW()
        icon(NSPoint(x: x + iconW / 2, y: midY))
        let labelW = rows.map { measured($0.label, font: Self.remLabelFont) }.max() ?? 0
        let textW  = rows.map { measured($0.text, font: Self.percentFont) }.max() ?? 0
        let labelX = x + iconW + Self.iconRowGap
        let barX   = labelX + labelW + Self.labelBarGap
        let textX  = barX + Self.segTrackW + Self.barTextGap

        let centers: [CGFloat] = rows.count == 1
            ? [midY]
            : rows.indices.map { midY + Self.rowOffset - CGFloat($0) * 2 * Self.rowOffset }
        for (row, cy) in zip(rows, centers) {
            let lAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.remLabelFont, .foregroundColor: NSColor.labelColor]
            let lStr = row.label as NSString
            let lSize = lStr.size(withAttributes: lAttrs)
            lStr.draw(at: NSPoint(x: labelX, y: cy - lSize.height / 2), withAttributes: lAttrs)

            let color = remainingColor(row.band)
            drawSegmentedBar(remaining: row.remaining, color: color, x: barX, centerY: cy)

            // Attention colours carry into the text; neutral rows stay plain.
            let tint: NSColor = (row.band == .warn || row.band == .critical) ? color : .labelColor
            let tAttrs: [NSAttributedString.Key: Any] = [.font: Self.percentFont, .foregroundColor: tint]
            let tStr = row.text as NSString
            let tSize = tStr.size(withAttributes: tAttrs)
            tStr.draw(at: NSPoint(x: textX, y: cy - tSize.height / 2), withAttributes: tAttrs)
        }
        return textX + textW
    }

    /// Five segments that drain from the right as capacity is used up; the fill
    /// is clipped to the segment shapes so partial segments read correctly.
    private func drawSegmentedBar(remaining: Int?, color: NSColor, x: CGFloat, centerY: CGFloat) {
        let y = centerY - Self.barH / 2
        let segments = NSBezierPath()
        for i in 0..<Self.segCount {
            let r = NSRect(x: x + CGFloat(i) * (Self.segW + Self.segGap), y: y, width: Self.segW, height: Self.barH)
            segments.appendRoundedRect(r, xRadius: 1, yRadius: 1)
        }
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        segments.fill()
        guard let remaining, remaining > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        segments.addClip()
        color.setFill()
        NSRect(x: x, y: y, width: Self.segTrackW * CGFloat(min(100, remaining)) / 100, height: Self.barH).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Center-dash style

    private static let dashNameFont = NSFont.systemFont(ofSize: 8, weight: .bold)
    private static let dashTrackW: CGFloat = 112
    private static let dashTrackH: CGFloat = 8
    private static let dashNameGap: CGFloat = 5
    private static let dashValueGap: CGFloat = 6
    private static let dashResetGap: CGFloat = 8
    private static let dashLength: CGFloat = 4
    private static let dashGap: CGFloat = 2.5
    private static let dashThickness: CGFloat = 2

    private struct CenterDashRow {
        let name: String
        /// Long window, drawn as the solid fill: weekly, or monthly on Codex
        /// plans that report no rate-limit windows.
        let week: Int?
        /// Five-hour window, drawn as the dashed overlay.
        let hour: Int?
        let valueText: String
        let resetsAt: Date?
    }

    private func centerDashRows() -> [CenterDashRow] {
        var rows: [CenterDashRow] = []
        if showsCodexColumn {
            let limits = codexSummary?.limitStatus
            let primary = limits?.primaryUsedPercent
            let secondary = limits?.secondaryUsedPercent
            if primary != nil || secondary != nil {
                rows.append(CenterDashRow(
                    name: "GPT", week: secondary, hour: primary,
                    valueText: "W\(secondary.map(String.init) ?? "–") · H\(primary.map(String.init) ?? "–")",
                    resetsAt: limits?.primaryResetsAt))
            } else if let plan = codexPlan {
                // Monthly is the long window, so it takes the solid fill.
                let sevenDay = codexSummary.map { formatCost($0.last7DaysCost) } ?? "–"
                rows.append(CenterDashRow(
                    name: "GPT", week: plan.usedPercent, hour: nil,
                    valueText: "MO\(plan.usedPercent) · 7D\(sevenDay)", resetsAt: plan.resetsAt))
            } else if let summary = codexSummary {
                let month = budgetFillPercent(monthCost: summary.monthToDateCost, budget: codexBudget)
                rows.append(CenterDashRow(
                    name: "GPT", week: month, hour: nil,
                    valueText: "MO\(month) · 7D\(formatCost(summary.last7DaysCost))",
                    resetsAt: startOfNextMonth(after: renderDate)))
            } else {
                rows.append(CenterDashRow(name: "GPT", week: nil, hour: nil,
                                          valueText: "MO– · 7D–", resetsAt: nil))
            }
        }
        if showsClaudeColumn {
            let hour = isDegraded ? nil : snapshot?.session?.percent
            let week = isDegraded ? nil : snapshot?.weeklyAll?.percent
            rows.append(CenterDashRow(name: "CLD",
                                      week: week,
                                      hour: hour,
                                      valueText: "W\(week.map(String.init) ?? "–") · H\(hour.map(String.init) ?? "–")",
                                      resetsAt: isDegraded ? nil : snapshot?.session?.resetsAt))
        }
        return rows
    }

    private func centerDashPreferredWidth() -> CGFloat {
        let rows = centerDashRows()
        let nameW = rows.map { measured($0.name, font: Self.dashNameFont) }.max() ?? 0
        let valueW = rows.map { measured($0.valueText, font: Self.percentFont) }.max() ?? 0
        let resetW = rows.map {
            measured("↻ \(menuBarCountdown(to: $0.resetsAt, from: renderDate))", font: Self.percentFont)
        }.max() ?? 0
        return 4 + nameW + Self.dashNameGap + Self.dashTrackW + Self.dashValueGap
            + valueW + Self.dashResetGap + resetW
    }

    private func drawCenterDash() {
        let rows = centerDashRows()
        guard !rows.isEmpty else { return }
        let midY = bounds.midY
        let centers: [CGFloat] = rows.count == 1
            ? [midY]
            : rows.indices.map { midY + Self.rowOffset - CGFloat($0) * 2 * Self.rowOffset }
        let nameW = rows.map { measured($0.name, font: Self.dashNameFont) }.max() ?? 0
        let valueW = rows.map { measured($0.valueText, font: Self.percentFont) }.max() ?? 0
        let nameX: CGFloat = 2
        let trackX = nameX + nameW + Self.dashNameGap
        let valueX = trackX + Self.dashTrackW + Self.dashValueGap

        for (row, cy) in zip(rows, centers) {
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.dashNameFont, .foregroundColor: NSColor.labelColor]
            let name = row.name as NSString
            let nameSize = name.size(withAttributes: nameAttrs)
            name.draw(at: NSPoint(x: nameX, y: cy - nameSize.height / 2), withAttributes: nameAttrs)
            drawCenterDashTrack(week: row.week, hour: row.hour, x: trackX, centerY: cy)
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.percentFont, .foregroundColor: NSColor.labelColor]
            let value = row.valueText as NSString
            let valueSize = value.size(withAttributes: valueAttrs)
            value.draw(at: NSPoint(x: valueX, y: cy - valueSize.height / 2), withAttributes: valueAttrs)

            let resetText = "↻ \(menuBarCountdown(to: row.resetsAt, from: renderDate))"
            let reset = resetText as NSString
            let resetSize = reset.size(withAttributes: valueAttrs)
            reset.draw(at: NSPoint(x: valueX + valueW + Self.dashResetGap,
                                   y: cy - resetSize.height / 2), withAttributes: valueAttrs)
        }

        let resetX = valueX + valueW + Self.dashResetGap
        NSColor.labelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(rect: NSRect(x: resetX - Self.dashResetGap / 2, y: midY - 8,
                                  width: 1, height: 16)).fill()
    }

    /// Solid fill = weekly (or monthly), dashed overlay = five-hour.
    ///
    /// WHY the dashes are cut out of the fill instead of stroked over it: the
    /// weekly fill usually runs past the five-hour mark, and same-ink dashes on
    /// top of it disappear. Punching them out (even-odd clip) keeps the 5h extent
    /// readable wherever it sits, in both menu bar appearances, without adding a
    /// colour to a monochrome menu bar. Past the end of the fill they are ink.
    private func drawCenterDashTrack(week: Int?, hour: Int?, x: CGFloat, centerY: CGFloat) {
        let track = NSRect(x: x, y: centerY - Self.dashTrackH / 2,
                           width: Self.dashTrackW, height: Self.dashTrackH)
        let radius = Self.dashTrackH / 2
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let dashes = NSBezierPath()
        if let hour, hour > 0 {
            let endX = x + Self.dashTrackW * CGFloat(hour) / 100
            let r = Self.dashThickness / 2
            var dashX = x + 1
            while dashX < endX {
                let w = min(Self.dashLength, endX - dashX)
                dashes.appendRoundedRect(NSRect(x: dashX, y: centerY - r, width: w, height: Self.dashThickness),
                                         xRadius: min(r, w / 2), yRadius: r)
                dashX += Self.dashLength + Self.dashGap
            }
        }

        var fill: NSBezierPath?
        if let week, week > 0 {
            let fillRect = NSRect(x: x, y: track.minY,
                                  width: Self.dashTrackW * CGFloat(week) / 100, height: Self.dashTrackH)
            let path = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            if !dashes.isEmpty {
                let knockout = NSBezierPath(rect: track)
                knockout.append(dashes)
                knockout.windingRule = .evenOdd
                knockout.addClip()
            }
            NSColor.labelColor.withAlphaComponent(0.48).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            fill = path
        }

        guard !dashes.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        if let fill {
            let outsideFill = NSBezierPath(rect: track)
            outsideFill.append(fill)
            outsideFill.windingRule = .evenOdd
            outsideFill.addClip()
        }
        NSColor.labelColor.setFill()
        dashes.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawClaudeIcon(center: NSPoint) {
        ProviderGlyph.drawClaude(center: center, fontSize: Self.iconFont.pointSize, color: .labelColor)
    }

    private func drawCodexIcon(center: NSPoint) {
        ProviderGlyph.drawCodex(center: center, diameter: Self.blossomSize, color: .labelColor)
    }

    // MARK: - Fill color

    private func fillColor(for percent: Int) -> NSColor {
        color(for: band(forPercent: percent))
    }

    private func color(for band: Band) -> NSColor {
        switch band {
        case .ok:       return .systemGreen
        case .warn:     return .systemYellow
        case .critical: return .systemRed
        }
    }

    // MARK: - Data helpers

    private struct SegmentEntry {
        let label: String
        let percent: Int
        let percentText: String
    }

    private func entriesForDisplay() -> (session: SegmentEntry, fable: SegmentEntry, week: SegmentEntry) {
        if isDegraded || snapshot == nil {
            return (
                session: SegmentEntry(label: menuBarShortLabel("5H"),    percent: 0, percentText: "–"),
                fable:   SegmentEntry(label: menuBarShortLabel("FABLE"), percent: 0, percentText: "–"),
                week:    SegmentEntry(label: menuBarShortLabel("WEEK"),  percent: 0, percentText: "–")
            )
        }
        let snap = snapshot!
        func entry(_ bucket: Bucket?, fallbackLabel: String) -> SegmentEntry {
            guard let b = bucket else {
                return SegmentEntry(label: menuBarShortLabel(fallbackLabel), percent: 0, percentText: "–")
            }
            return SegmentEntry(label: menuBarShortLabel(b.label), percent: b.percent, percentText: "\(b.percent)%")
        }
        return (
            session: entry(snap.session,      fallbackLabel: "5H"),
            fable:   entry(snap.weeklyScoped, fallbackLabel: "FABLE"),
            week:    entry(snap.weeklyAll,    fallbackLabel: "WEEK")
        )
    }

    private func timeText() -> String {
        if isDegraded { return "–:–" }
        return menuBarTime(resetDate)
    }

    /// Codex cell values; dashes when the scan hasn't produced a summary yet.
    private struct CodexDisplay {
        let day: String
        let week: String
        let month: String
        let monthPercent: Int
        let monthColor: NSColor
        /// Short monthly-reset date ("8/31") — only when the real spend-control
        /// limit is reported; nil drops the RST cell.
        let monthReset: String?
    }

    private func codexDisplay() -> CodexDisplay {
        // MO cell: prefer the real monthly limit percent (ChatGPT spend control,
        // standard limit bands); fall back to the local $-budget barometer.
        let month: String
        let monthPercent: Int
        let monthColor: NSColor
        let monthReset: String?
        if let plan = codexPlan {
            month = "\(plan.usedPercent)%"
            monthPercent = plan.usedPercent
            monthColor = fillColor(for: plan.usedPercent)
            monthReset = menuBarShortDate(plan.resetsAt)
        } else if let s = codexSummary {
            let mtd = s.monthToDateCost
            month = codexShowsDollars ? formatCost(mtd) : formatTokens(s.monthToDateTotal)
            monthPercent = budgetFillPercent(monthCost: mtd, budget: codexBudget)
            monthColor = color(for: budgetBand(monthCost: mtd, budget: codexBudget))
            monthReset = nil
        } else {
            month = "–"
            monthPercent = 0
            monthColor = .labelColor
            monthReset = nil
        }

        guard let s = codexSummary else {
            return CodexDisplay(day: "–", week: "–", month: month,
                                monthPercent: monthPercent, monthColor: monthColor,
                                monthReset: monthReset)
        }
        return CodexDisplay(
            day:  codexShowsDollars ? formatCost(s.todayCost)     : formatTokens(s.todayTotal),
            week: codexShowsDollars ? formatCost(s.last7DaysCost) : formatTokens(s.last7DaysTotal),
            month: month,
            monthPercent: monthPercent, monthColor: monthColor,
            monthReset: monthReset)
    }

}
