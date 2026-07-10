/// StatusBarView.swift — Stats-style compact usage display for the macOS menu bar.
///
/// Custom NSView subclass that draws three usage segments (5H / FABLE / WEEK) each
/// with a mini label stacked above a progress bar + percent value, separated by thin
/// vertical dividers, with the 5h reset time on the right. Visual style inspired by
/// the Stats menu bar app (tiny label + value pairs, thin separators).
///
/// Rendering is pure NSColor / NSBezierPath so it adapts automatically to light/dark
/// menu bar appearance (all colors are dynamic NSColor semantics).

import AppKit
import ClusageCore

final class StatusBarView: NSView {

    // MARK: - Layout constants

    /// Full content height (22pt = standard macOS menu bar content area).
    private static let barHeight: CGFloat = 22
    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    // Mini progress bar dimensions
    private static let barW: CGFloat = 24
    private static let barH: CGFloat = 3
    private static let barCorner: CGFloat = 1.5

    // Gap between bar and percent text
    private static let barTextGap: CGFloat = 3

    // Vertical separator dimensions
    private static let sepW: CGFloat = 1
    private static let sepH: CGFloat = 12
    private static let sepPad: CGFloat = 6   // horizontal padding each side of the separator

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
        let buckets = bucketsForDisplay()
        var w: CGFloat = 0
        for (i, entry) in buckets.enumerated() {
            if i > 0 { w += Self.sepPad * 2 + Self.sepW }
            w += segmentWidth(entry.label, percentText: entry.percentText)
        }
        // separator before time
        w += Self.sepPad * 2 + Self.sepW
        // time text
        let timeStr = timeText()
        w += (timeStr as NSString).size(withAttributes: [.font: Self.valueFont]).width
        return w + 4   // 2pt padding each side
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let buckets = bucketsForDisplay()
        let midY = bounds.midY
        var x: CGFloat = 2   // left padding

        for (i, entry) in buckets.enumerated() {
            if i > 0 { x = drawSeparator(x: x, midY: midY) }
            x = drawSegment(entry: entry, x: x, midY: midY)
        }

        // Separator before time
        x = drawSeparator(x: x, midY: midY)

        // Time block
        let tStr = timeText() as NSString
        let tAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.valueFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let tSize = tStr.size(withAttributes: tAttrs)
        let tRect = NSRect(x: x, y: midY - tSize.height / 2, width: tSize.width, height: tSize.height)
        tStr.draw(in: tRect, withAttributes: tAttrs)
    }

    // MARK: - Segment drawing

    @discardableResult
    private func drawSegment(entry: SegmentEntry, x: CGFloat, midY: CGFloat) -> CGFloat {
        var cx = x

        // Vertical layout: label on top, value row below
        let labelH = (entry.label as NSString).size(withAttributes: [.font: Self.labelFont]).height
        let valueH = Self.barH    // reference height for vertical centre of value row
        let totalH = labelH + 2 + max(valueH, Self.valueFont.capHeight)

        let valueRowY = midY - totalH / 2              // bottom of value row area
        let labelY    = valueRowY + max(valueH, Self.valueFont.capHeight) + 2

        // -- Label --
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let labelStr = entry.label as NSString
        let labelW = labelStr.size(withAttributes: labelAttrs).width

        // Compute full segment width for label centering
        let segW = segmentWidth(entry.label, percentText: entry.percentText)
        let labelX = cx + (segW - labelW) / 2
        labelStr.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttrs)

        // -- Mini progress bar (track) --
        let barY = valueRowY + (max(valueH, Self.valueFont.capHeight) - Self.barH) / 2
        let trackRect = NSRect(x: cx, y: barY, width: Self.barW, height: Self.barH)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: Self.barCorner, yRadius: Self.barCorner)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        trackPath.fill()

        // -- Mini progress bar (fill) --
        let fillW = CGFloat(entry.percent) / 100 * Self.barW
        if fillW > 0 {
            let fillRect = NSRect(x: cx, y: barY, width: fillW, height: Self.barH)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: Self.barCorner, yRadius: Self.barCorner)
            fillColor(for: entry.percent).setFill()
            fillPath.fill()
        }

        cx += Self.barW + Self.barTextGap

        // -- Percent text --
        let pStr = entry.percentText as NSString
        let pAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.valueFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let pH = pStr.size(withAttributes: pAttrs).height
        let pY = valueRowY + (max(valueH, Self.valueFont.capHeight) - pH) / 2
        pStr.draw(at: NSPoint(x: cx, y: pY), withAttributes: pAttrs)
        cx += pStr.size(withAttributes: pAttrs).width

        return cx
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
                SegmentEntry(label: "5H",   percent: 0, percentText: "–"),
                SegmentEntry(label: "FABLE",percent: 0, percentText: "–"),
                SegmentEntry(label: "WEEK", percent: 0, percentText: "–"),
            ]
        }
        let snap = snapshot!
        func entry(_ bucket: Bucket?, fallbackLabel: String) -> SegmentEntry {
            guard let b = bucket else {
                return SegmentEntry(label: fallbackLabel, percent: 0, percentText: "–")
            }
            return SegmentEntry(label: b.label, percent: b.percent, percentText: "\(b.percent)%")
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

    private func segmentWidth(_ label: String, percentText: String) -> CGFloat {
        let labelW = (label as NSString).size(withAttributes: [.font: Self.labelFont]).width
        let pW = (percentText as NSString).size(withAttributes: [.font: Self.valueFont]).width
        let valueRowW = Self.barW + Self.barTextGap + pW
        return max(labelW, valueRowW)
    }
}
