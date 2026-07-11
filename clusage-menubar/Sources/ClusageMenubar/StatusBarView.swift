/// StatusBarView.swift — Stats-style compact usage display for the macOS menu bar.
///
/// Custom NSView subclass that draws a 2×2 grid of usage rows:
///   Left column:  5H gauge (top)    /  RESETS <time> (bottom)
///   Right column: WK gauge  (top)   /  F gauge        (bottom)
/// Columns are separated by a vertical rule. 7pt labels / 9pt monospaced-digit values.
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
        let m = gridMetrics()
        return 2 + m.leftColW + Self.sepPad + Self.sepW + Self.sepPad + m.rightColW + 2
    }

    // MARK: - Grid metrics

    private struct GridMetrics {
        let leftLabelW: CGFloat   // "5H"-entry label only — RESETS row is independent
        let rightLabelW: CGFloat   // max(week label, fable label) at labelFont
        let pctW: CGFloat          // max percentText over all 3 entries at percentFont
        let leftColW: CGFloat
        let rightColW: CGFloat
    }

    private func gridMetrics() -> GridMetrics {
        let e = entriesForDisplay()

        func measuredLabelW(_ s: String) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: Self.labelFont]).width)
        }
        func measuredPctW(_ s: String) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: Self.percentFont]).width)
        }

        let leftLabelW  = measuredLabelW(e.session.label)   // "5H" only; RESETS doesn't inflate the bar column
        let rightLabelW = max(measuredLabelW(e.week.label), measuredLabelW(e.fable.label))
        let allPctW     = max(measuredPctW(e.session.percentText),
                          max(measuredPctW(e.fable.percentText), measuredPctW(e.week.percentText)))

        func gaugeRowW(_ lw: CGFloat) -> CGFloat {
            lw + Self.labelBarGap + Self.barW + Self.barTextGap + allPctW
        }
        let resetLabelW = measuredLabelW(Self.resetLabel)
        let timeStrW    = ceil((timeText() as NSString).size(withAttributes: [.font: Self.timeFont]).width)
        let timeRowW    = resetLabelW + 2 + timeStrW   // compact: "RESETS" + 2pt gap + time, no column alignment

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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let e = entriesForDisplay()
        let m = gridMetrics()
        let midY = bounds.midY
        let x0: CGFloat = 2

        drawRow(entry: e.session, x: x0, centerY: midY + Self.rowOffset, labelW: m.leftLabelW,  pctW: m.pctW)
        drawTimeRow(x: x0, centerY: midY - Self.rowOffset)

        let rx = drawSeparator(x: x0 + m.leftColW, midY: midY)

        drawRow(entry: e.week,  x: rx, centerY: midY + Self.rowOffset, labelW: m.rightLabelW, pctW: m.pctW)
        drawRow(entry: e.fable, x: rx, centerY: midY - Self.rowOffset, labelW: m.rightLabelW, pctW: m.pctW)
    }

    // MARK: - Row drawing

    private func drawRow(entry: SegmentEntry, x: CGFloat, centerY: CGFloat, labelW: CGFloat, pctW: CGFloat) {
        // -- Label: right-aligned in its column, vertically centered on the row --
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelStr  = entry.label as NSString
        let labelSize = labelStr.size(withAttributes: labelAttrs)
        labelStr.draw(at: NSPoint(x: x + labelW - labelSize.width,
                                  y: centerY - labelSize.height / 2),
                      withAttributes: labelAttrs)

        // -- Mini progress bar (track + fill), reusing fillColor(for:) --
        let barX      = x + labelW + Self.labelBarGap
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
        let pStr  = entry.percentText as NSString
        let pSize = pStr.size(withAttributes: pAttrs)
        pStr.draw(at: NSPoint(x: barX + Self.barW + Self.barTextGap + pctW - pSize.width,
                              y: centerY - pSize.height / 2),
                  withAttributes: pAttrs)
    }

    /// Draw the RESETS label and reset-time string as a compact pair in the bottom-left cell.
    private func drawTimeRow(x: CGFloat, centerY: CGFloat) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let rStr  = Self.resetLabel as NSString
        let rSize = rStr.size(withAttributes: labelAttrs)
        rStr.draw(at: NSPoint(x: x, y: centerY - rSize.height / 2), withAttributes: labelAttrs)

        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.timeFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let tStr  = timeText() as NSString
        let tSize = tStr.size(withAttributes: timeAttrs)
        tStr.draw(at: NSPoint(x: x + rSize.width + 2,
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

}
