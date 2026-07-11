/// StatusBarView.swift — Stats-style compact usage display for the macOS menu bar.
///
/// Custom NSView subclass that draws three stacked rows (top → bottom: 5H / model / WEEK),
/// each row = tiny right-aligned label + mini progress bar + tiny percent, with the 5h
/// reset time on the right. Visual style inspired by the Stats menu bar app (Mockup D,
/// chosen 2026-07-10).
///
/// Rendering is pure NSColor / NSBezierPath so it adapts automatically to light/dark
/// menu bar appearance (all colors are dynamic NSColor semantics).

import AppKit
import ClusageCore

final class StatusBarView: NSView {

    // MARK: - Layout constants

    /// Full content height (22pt = standard macOS menu bar content area).
    private static let barHeight: CGFloat = 22
    /// Vertical pitch between stacked row centers: 3 rows × 7pt ≈ 21pt in 22pt.
    private static let rowPitch: CGFloat = 7

    // Fonts. Stacked rows cap text at tiny sizes (Mockup D, chosen 2026-07-10):
    // 5pt labels / 6.5pt percents; the reset time keeps the old 11pt for glanceability.
    private static let labelFont = NSFont.systemFont(ofSize: 5, weight: .semibold)
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .medium)
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    // Mini progress bar dimensions
    private static let barW: CGFloat = 16
    private static let barH: CGFloat = 3
    private static let barCorner: CGFloat = 1.5

    // Horizontal gaps inside a row
    private static let labelBarGap: CGFloat = 2   // label column → bar
    private static let barTextGap: CGFloat = 3    // bar → percent column

    // Vertical separator dimensions (unchanged from horizontal layout)
    private static let sepW: CGFloat = 1
    private static let sepH: CGFloat = 12
    private static let sepPad: CGFloat = 6

    // MARK: - State

    var snapshot: UsageSnapshot?
    var resetDate: Date?    // session.resetsAt — shown on the right as the compact reset time
    var isDegraded = false

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
        let entries = bucketsForDisplay()
        let cols = columnWidths(entries)
        let rowW = cols.label + Self.labelBarGap + Self.barW + Self.barTextGap + cols.pct
        let timeW = (timeText() as NSString).size(withAttributes: [.font: Self.timeFont]).width
        return 2 + rowW + Self.sepPad * 2 + Self.sepW + ceil(timeW) + 2   // 2pt padding each side
    }

    /// Label and percent column widths for the current entries. Columns are sized
    /// to the widest string so rows align; percent digits are tabular already.
    private func columnWidths(_ entries: [SegmentEntry]) -> (label: CGFloat, pct: CGFloat) {
        var labelW: CGFloat = 0
        var pctW: CGFloat = 0
        for e in entries {
            labelW = max(labelW, (e.label as NSString).size(withAttributes: [.font: Self.labelFont]).width)
            pctW   = max(pctW,   (e.percentText as NSString).size(withAttributes: [.font: Self.percentFont]).width)
        }
        return (ceil(labelW), ceil(pctW))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let entries = bucketsForDisplay()
        let cols = columnWidths(entries)
        let midY = bounds.midY
        let x: CGFloat = 2   // left padding

        // Rows stacked top→bottom: 5H / model / WEEK, centered on midY.
        for (i, entry) in entries.enumerated() {
            let rowCenterY = midY + Self.rowPitch * CGFloat(1 - i)   // +7, 0, -7
            drawRow(entry: entry, x: x, centerY: rowCenterY, cols: cols)
        }

        let rowW = cols.label + Self.labelBarGap + Self.barW + Self.barTextGap + cols.pct
        let tx = drawSeparator(x: x + rowW, midY: midY)

        // Time block (unchanged behavior, font constant renamed to timeFont)
        let tStr = timeText() as NSString
        let tAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.timeFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let tSize = tStr.size(withAttributes: tAttrs)
        tStr.draw(in: NSRect(x: tx, y: midY - tSize.height / 2, width: tSize.width, height: tSize.height),
                  withAttributes: tAttrs)
    }

    // MARK: - Row drawing

    private func drawRow(entry: SegmentEntry, x: CGFloat, centerY: CGFloat, cols: (label: CGFloat, pct: CGFloat)) {
        // -- Label: right-aligned in its column, vertically centered on the row --
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelStr = entry.label as NSString
        let labelSize = labelStr.size(withAttributes: labelAttrs)
        labelStr.draw(at: NSPoint(x: x + cols.label - labelSize.width,
                                  y: centerY - labelSize.height / 2),
                      withAttributes: labelAttrs)

        // -- Mini progress bar (track + fill), reusing fillColor(for:) --
        let barX = x + cols.label + Self.labelBarGap
        let trackRect = NSRect(x: barX, y: centerY - Self.barH / 2, width: Self.barW, height: Self.barH)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: Self.barCorner, yRadius: Self.barCorner).fill()
        let fillW = CGFloat(entry.percent) / 100 * Self.barW
        if fillW > 0 {
            let fillRect = NSRect(x: barX, y: centerY - Self.barH / 2, width: fillW, height: Self.barH)
            fillColor(for: entry.percent).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: Self.barCorner, yRadius: Self.barCorner).fill()
        }

        // -- Percent: right-aligned in its column so digits line up --
        let pAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.percentFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let pStr = entry.percentText as NSString
        let pSize = pStr.size(withAttributes: pAttrs)
        pStr.draw(at: NSPoint(x: barX + Self.barW + Self.barTextGap + cols.pct - pSize.width,
                              y: centerY - pSize.height / 2),
                  withAttributes: pAttrs)
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

    // MARK: - Fill color

    private func fillColor(for percent: Int) -> NSColor {
        switch band(forPercent: percent) {
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

    private func bucketsForDisplay() -> [SegmentEntry] {
        if isDegraded || snapshot == nil {
            return [
                SegmentEntry(label: menuBarShortLabel("5H"),    percent: 0, percentText: "–"),
                SegmentEntry(label: menuBarShortLabel("FABLE"), percent: 0, percentText: "–"),
                SegmentEntry(label: menuBarShortLabel("WEEK"),  percent: 0, percentText: "–"),
            ]
        }
        let snap = snapshot!
        func entry(_ bucket: Bucket?, fallbackLabel: String) -> SegmentEntry {
            guard let b = bucket else {
                return SegmentEntry(label: menuBarShortLabel(fallbackLabel), percent: 0, percentText: "–")
            }
            return SegmentEntry(label: menuBarShortLabel(b.label), percent: b.percent, percentText: "\(b.percent)%")
        }
        return [
            entry(snap.session,      fallbackLabel: "5H"),
            entry(snap.weeklyScoped, fallbackLabel: "FABLE"),
            entry(snap.weeklyAll,    fallbackLabel: "WEEK"),
        ]
    }

    private func timeText() -> String {
        if isDegraded { return "–:–" }
        return menuBarTime(resetDate)
    }

}
