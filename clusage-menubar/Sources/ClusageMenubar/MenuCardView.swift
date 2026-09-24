/// MenuCardView.swift — draws a ClusageCore.UsageCard as a dropdown menu item.
///
/// Plain AppKit drawing, like StatusBarView: an NSMenuItem.view with a fixed
/// width and a height measured from the card's blocks. Custom item views span
/// the full menu width (probed on macOS 26: x = 0…menu width). Native item text
/// starts at 14pt, glyphs at 16pt, while no item in the menu shows a checkmark,
/// and moves to 22pt once one does; the top level has none (preferences live in
/// Settings), so the insets below line card text up with "Refresh Now" and with
/// the native separators' ends.
///
/// Colour follows one rule set: meters fill in the accent until a limit needs
/// attention (warning amber, critical red — always with an icon and words, never
/// colour alone); the daily chart greys every day but today; text always wears
/// label ink, never the data colour.

import AppKit
import ClusageCore

// MARK: - Palette

/// Steps from the dataviz reference palette (series slot 1 and the fixed status
/// scale), resolved per appearance so dark menus get their own step, not a flip.
enum CardPalette {
    static let accent = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let warning = rgb(0xFAB219)
    static let critical = rgb(0xD03B3B)

    static func fill(for severity: UsageSeverity) -> NSColor {
        switch severity {
        case .normal:   return accent
        case .warning:  return warning
        case .critical: return critical
        }
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }
}

// MARK: - Card view

final class MenuCardView: NSView, NSViewToolTipOwner {

    // MARK: Metrics

    static let width: CGFloat = 340
    /// Native item glyphs start here in a menu without a checkmark column
    /// (text field at 14pt + 2pt cell inset).
    static let leading: CGFloat = 16
    /// Where native separators and key equivalents end.
    static let trailing: CGFloat = 16
    /// Provider glyph and callout symbol sit inline, text starts this far in.
    private static let iconIndent: CGFloat = 17

    private static let padTop: CGFloat = 4
    private static let padBottom: CGFloat = 8
    private static let headerH: CGFloat = 20

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let rowFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Tabular digits: meter values right-align in a column across meters.
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let smallFont = NSFont.systemFont(ofSize: 11)
    private static let smallDigits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let captionFont = NSFont.systemFont(ofSize: 10)
    private static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    /// Proportional figures: stat values stand alone, they don't form a column.
    private static let statFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let sectionFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    // Meter
    private static let meterLine1H: CGFloat = 16
    private static let barH: CGFloat = 6
    private static let markerW: CGFloat = 2
    /// Surface gap either side of the marker, cut out of the bar.
    private static let markerGap: CGFloat = 1
    private static let markerOverhang: CGFloat = 2
    private static let meterLine3H: CGFloat = 14
    private static var meterH: CGFloat {
        meterLine1H + 4 + markerOverhang + barH + markerOverhang + 3 + meterLine3H
    }

    // Stats
    private static let statGap: CGFloat = 10
    private static let statH: CGFloat = 14 + 19 + 13

    // Chart
    private static let sectionTitleH: CGFloat = 16
    private static let peakLabelH: CGFloat = 12
    private static let plotH: CGFloat = 28
    private static let axisLabelH: CGFloat = 12
    private static let columnGap: CGFloat = 2
    private static var chartH: CGFloat { sectionTitleH + 4 + peakLabelH + plotH + 3 + axisLabelH }

    // Breakdown
    private static let breakdownRowH: CGFloat = 17
    private static let breakdownNameW: CGFloat = 122
    private static let breakdownBarH: CGFloat = 5

    private static let noteH: CGFloat = 14

    // MARK: State

    private let card: UsageCard
    private var toolTipText: [NSView.ToolTipTag: String] = [:]

    init(card: UsageCard) {
        self.card = card
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(of: card)))
        autoresizingMask = [.width]
        rebuildToolTips()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildToolTips()   // chart column rects depend on the width
    }

    private var contentLeft: CGFloat { Self.leading }
    private var contentRight: CGFloat { bounds.width - Self.trailing }
    private var contentW: CGFloat { contentRight - contentLeft }

    // MARK: Layout

    private static func height(of block: UsageCardBlock) -> CGFloat {
        switch block {
        case .meter:              return meterH
        case .stats:              return statH
        case .dailyChart:         return chartH
        case .breakdown(let b):   return sectionTitleH + 4 + CGFloat(b.rows.count) * breakdownRowH
        case .callout(let c):     return 16 + (c.detail == nil ? 0 : 14)
        case .note:               return noteH
        }
    }

    private static func gap(after previous: UsageCardBlock?, before block: UsageCardBlock) -> CGFloat {
        switch (previous, block) {
        case (nil, _):              return 7
        case (.meter?, .meter):     return 10
        case (.note?, .note):       return 2
        default:                    return 12
        }
    }

    private static func height(of card: UsageCard) -> CGFloat {
        var h = padTop + headerH
        var previous: UsageCardBlock?
        for block in card.blocks {
            h += gap(after: previous, before: block) + height(of: block)
            previous = block
        }
        return ceil(h + padBottom)
    }

    /// (block, top y) pairs in draw order; the single source for drawing and
    /// tooltip placement so the two can't disagree.
    private func blockOrigins() -> [(block: UsageCardBlock, y: CGFloat)] {
        var y = Self.padTop + Self.headerH
        var previous: UsageCardBlock?
        var out: [(UsageCardBlock, CGFloat)] = []
        for block in card.blocks {
            y += Self.gap(after: previous, before: block)
            out.append((block, y))
            y += Self.height(of: block)
            previous = block
        }
        return out
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawHeader(y: Self.padTop)
        for (block, y) in blockOrigins() {
            switch block {
            case .meter(let m):      drawMeter(m, y: y)
            case .stats(let s):      drawStats(s, y: y)
            case .dailyChart(let c): drawChart(c, y: y)
            case .breakdown(let b):  drawBreakdown(b, y: y)
            case .callout(let c):    drawCallout(c, y: y)
            case .note(let n):       drawNote(n, y: y)
            }
        }
    }

    private func drawHeader(y: CGFloat) {
        let midY = y + Self.headerH / 2
        let glyphCenter = NSPoint(x: contentLeft + 6, y: midY)
        switch card.provider {
        case .claude: ProviderGlyph.drawClaude(center: glyphCenter, fontSize: 14, color: .labelColor)
        case .codex:  ProviderGlyph.drawCodex(center: glyphCenter, diameter: 11, color: .labelColor)
        }
        let titleX = contentLeft + Self.iconIndent
        let title = Self.text(card.title, Self.titleFont, .labelColor)
        let titleSize = title.size()
        title.draw(at: NSPoint(x: titleX, y: midY - titleSize.height / 2))

        var freshnessW: CGFloat = 0
        if let freshness = card.freshness {
            let f = Self.text(freshness, Self.smallFont, .secondaryLabelColor)
            let size = f.size()
            freshnessW = size.width
            f.draw(at: NSPoint(x: contentRight - size.width, y: midY - size.height / 2))
        }
        if let badge = card.badge {
            let b = Self.text(badge, Self.badgeFont, .secondaryLabelColor)
            let size = b.size()
            let x = titleX + titleSize.width + 7
            let capsule = NSRect(x: x, y: midY - size.height / 2 - 1, width: size.width + 10, height: size.height + 2)
            guard capsule.maxX < contentRight - freshnessW - 8 else { return }
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
            b.draw(at: NSPoint(x: x + 5, y: midY - size.height / 2))
        }
    }

    // MARK: Meter

    private func drawMeter(_ m: UsageMeter, y: CGFloat) {
        // Line 1: title + subtitle, value right-aligned. Both lines carry a 13pt
        // run, so drawing them at the same y lines their baselines up.
        let title = NSMutableAttributedString(attributedString: Self.text(m.title, Self.rowFont, .labelColor))
        if let subtitle = m.subtitle {
            title.append(Self.text("  " + subtitle, Self.smallFont, .secondaryLabelColor))
        }
        let value = Self.emphasisedValue(m.valueText)
        let valueSize = value.size()
        value.draw(at: NSPoint(x: contentRight - valueSize.width, y: y))
        Self.drawTruncated(title, x: contentLeft, y: y, maxWidth: contentW - valueSize.width - 10)

        let barTop = y + Self.meterLine1H + 4 + Self.markerOverhang
        drawMeterBar(m, rect: NSRect(x: contentLeft, y: barTop, width: contentW, height: Self.barH))

        let line3Y = barTop + Self.barH + Self.markerOverhang + 3
        var statusW: CGFloat = 0
        if let status = m.status {
            statusW = drawStatus(status, rightEdge: contentRight, y: line3Y)
        }
        Self.drawTruncated(Self.text(m.detail, Self.smallFont, .secondaryLabelColor),
                           x: contentLeft, y: line3Y, maxWidth: contentW - statusW - 10)
    }

    /// "10% used" → bold "10%" + quiet " used"; "–" stays as is.
    private static func emphasisedValue(_ value: String) -> NSAttributedString {
        guard let space = value.firstIndex(of: " ") else { return text(value, valueFont, .labelColor) }
        let out = NSMutableAttributedString(attributedString: text(String(value[..<space]), valueFont, .labelColor))
        out.append(text(String(value[space...]), smallFont, .secondaryLabelColor))
        return out
    }

    private func drawMeterBar(_ m: UsageMeter, rect: NSRect) {
        let color = CardPalette.fill(for: m.severity)
        let radius = rect.height / 2
        let markerX = m.paceMarkerPercent.map {
            rect.minX + rect.width * CGFloat(min(100, max(0, $0))) / 100
        }

        NSGraphicsContext.saveGraphicsState()
        if let markerX {
            // Cut a surface-coloured gap around the marker so it reads on the
            // fill and the track alike, without drawing a border.
            let slot = NSRect(x: markerX - Self.markerW / 2 - Self.markerGap, y: rect.minY - 1,
                              width: Self.markerW + 2 * Self.markerGap, height: rect.height + 2)
            let clip = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
            clip.append(NSBezierPath(rect: slot))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        // Track is a lighter step of the fill's own hue, so state reads across
        // the whole bar; an empty meter ("no data") gets a neutral track.
        (m.fillPercent == nil ? NSColor.labelColor.withAlphaComponent(0.10) : color.withAlphaComponent(0.22)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if let percent = m.fillPercent, percent > 0 {
            // At least one bar-height wide so a 1% sliver still shows its round cap.
            let w = max(rect.height, rect.width * CGFloat(min(100, percent)) / 100)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                         xRadius: radius, yRadius: radius).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        if let markerX {
            NSColor.labelColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: markerX - Self.markerW / 2, y: rect.minY - Self.markerOverhang,
                                             width: Self.markerW, height: rect.height + 2 * Self.markerOverhang),
                         xRadius: Self.markerW / 2, yRadius: Self.markerW / 2).fill()
        }
    }

    /// Right-aligned status text; warning/critical get a coloured symbol and
    /// primary ink so the state never rests on colour alone. Returns its width.
    @discardableResult
    private func drawStatus(_ status: UsageStatusText, rightEdge: CGFloat, y: CGFloat) -> CGFloat {
        let ink: NSColor = status.severity == .normal ? .secondaryLabelColor : .labelColor
        let str = Self.text(status.text, Self.smallFont, ink)
        let size = str.size()
        str.draw(at: NSPoint(x: rightEdge - size.width, y: y))
        guard let symbol = Self.symbolName(for: status.severity) else { return size.width }
        let iconW = drawSymbol(symbol, color: CardPalette.fill(for: status.severity), pointSize: 10,
                               rightEdge: rightEdge - size.width - 4, centerY: y + size.height / 2)
        return size.width + 4 + iconW
    }

    private static func symbolName(for severity: UsageSeverity) -> String? {
        switch severity {
        case .normal:   return nil
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    /// Draws an SF Symbol ending at `rightEdge` (or starting at `leftEdge`);
    /// returns its width, 0 when the symbol is unavailable.
    @discardableResult
    private func drawSymbol(_ name: String, color: NSColor, pointSize: CGFloat,
                            rightEdge: CGFloat? = nil, leftEdge: CGFloat? = nil, centerY: CGFloat) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return 0 }
        let size = image.size
        let x = leftEdge ?? ((rightEdge ?? 0) - size.width)
        image.draw(in: NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return size.width
    }

    // MARK: Stats

    private func drawStats(_ stats: [UsageStat], y: CGFloat) {
        guard !stats.isEmpty else { return }
        let n = CGFloat(stats.count)
        let colW = (contentW - Self.statGap * (n - 1)) / n
        for (i, stat) in stats.enumerated() {
            let x = contentLeft + CGFloat(i) * (colW + Self.statGap)
            Self.drawTruncated(Self.text(stat.label, Self.captionFont, .secondaryLabelColor), x: x, y: y, maxWidth: colW)
            Self.drawTruncated(Self.text(stat.value, Self.statFont, .labelColor), x: x, y: y + 13, maxWidth: colW)
            if let detail = stat.detail {
                Self.drawTruncated(Self.text(detail, Self.captionFont, .secondaryLabelColor),
                                   x: x, y: y + 13 + 20, maxWidth: colW)
            }
        }
    }

    // MARK: Daily chart

    private func drawSectionTitle(_ title: String, subtitle: String?, trailing: String?, y: CGFloat) {
        var trailingW: CGFloat = 0
        if let trailing {
            let t = Self.text(trailing, Self.smallDigits, .secondaryLabelColor)
            let size = t.size()
            trailingW = size.width
            t.draw(at: NSPoint(x: contentRight - size.width, y: y + 1))
        }
        let str = NSMutableAttributedString(attributedString: Self.text(title, Self.sectionFont, .labelColor))
        if let subtitle { str.append(Self.text("  " + subtitle, Self.smallFont, .secondaryLabelColor)) }
        Self.drawTruncated(str, x: contentLeft, y: y, maxWidth: contentW - trailingW - 10)
    }

    /// Column slots for the chart block starting at `y`, in view coordinates.
    private func chartColumns(_ chart: UsageDailyChart, y: CGFloat) -> (slots: [NSRect], baseline: CGFloat) {
        let plotTop = y + Self.sectionTitleH + 4 + Self.peakLabelH
        let baseline = plotTop + Self.plotH
        let n = CGFloat(max(1, chart.values.count))
        let slotW = contentW / n
        let slots = chart.values.indices.map {
            NSRect(x: contentLeft + CGFloat($0) * slotW, y: plotTop - Self.peakLabelH,
                   width: slotW, height: Self.peakLabelH + Self.plotH)
        }
        return (slots, baseline)
    }

    private func drawChart(_ chart: UsageDailyChart, y: CGFloat) {
        drawSectionTitle(chart.title, subtitle: chart.subtitle, trailing: chart.trailing, y: y)
        let (slots, baseline) = chartColumns(chart, y: y)
        let maxValue = chart.values.max() ?? 0

        // Baseline hairline, recessive.
        NSColor.separatorColor.setFill()
        NSRect(x: contentLeft, y: baseline, width: contentW, height: 1 / max(1, window?.backingScaleFactor ?? 2)).fill()

        let deEmphasis = NSColor.labelColor.withAlphaComponent(0.30)
        for (i, value) in chart.values.enumerated() where value > 0 && maxValue > 0 {
            let slot = slots[i]
            let barW = min(24, max(1, slot.width - Self.columnGap))
            // Floor of 2pt so a light day still registers as "some use".
            let h = max(2, CGFloat(value / maxValue) * Self.plotH)
            let r = min(2, barW / 2, h / 2)
            let x = slot.midX - barW / 2
            NSGraphicsContext.saveGraphicsState()
            // Rounded data-end, square at the baseline: round all four corners,
            // then clip the bottom ones off at the baseline.
            NSRect(x: x, y: baseline - h, width: barW, height: h).clip()
            (i == chart.values.count - 1 ? CardPalette.accent : deEmphasis).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseline - h, width: barW, height: h + r),
                         xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // The one direct label on the plot: the peak's value, centred over it.
        if let peak = chart.peakIndex, let label = chart.peakLabel, slots.indices.contains(peak), maxValue > 0 {
            let str = Self.text(label, Self.captionFont, .secondaryLabelColor)
            let size = str.size()
            let x = min(max(contentLeft, slots[peak].midX - size.width / 2), contentRight - size.width)
            str.draw(at: NSPoint(x: x, y: baseline - Self.plotH - size.height - 1))
        }

        let axisY = baseline + 3
        let start = Self.text(chart.startLabel, Self.captionFont, .tertiaryLabelColor)
        start.draw(at: NSPoint(x: contentLeft, y: axisY))
        let end = Self.text(chart.endLabel, Self.captionFont, .tertiaryLabelColor)
        end.draw(at: NSPoint(x: contentRight - end.size().width, y: axisY))
    }

    // MARK: Breakdown

    private func drawBreakdown(_ b: UsageBreakdown, y: CGFloat) {
        drawSectionTitle(b.title, subtitle: b.subtitle, trailing: nil, y: y)
        let values = b.rows.map { Self.text($0.value, Self.smallDigits, .secondaryLabelColor) }
        let valueW = values.map { $0.size().width }.max() ?? 0
        let barX = contentLeft + Self.breakdownNameW + 8
        let barMaxW = max(0, contentRight - valueW - 10 - barX)
        for (i, row) in b.rows.enumerated() {
            let rowY = y + Self.sectionTitleH + 4 + CGFloat(i) * Self.breakdownRowH
            Self.drawTruncated(Self.text(row.name, Self.smallFont, .labelColor),
                               x: contentLeft, y: rowY, maxWidth: Self.breakdownNameW)
            let size = values[i].size()
            values[i].draw(at: NSPoint(x: contentRight - size.width, y: rowY))
            let midY = rowY + size.height / 2
            let barRect = NSRect(x: barX, y: midY - Self.breakdownBarH / 2, width: barMaxW, height: Self.breakdownBarH)
            let r = Self.breakdownBarH / 2
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: r, yRadius: r).fill()
            if row.fraction > 0 {
                CardPalette.accent.setFill()
                let w = max(Self.breakdownBarH, barMaxW * CGFloat(min(1, row.fraction)))
                NSBezierPath(roundedRect: NSRect(x: barX, y: barRect.minY, width: w, height: Self.breakdownBarH),
                             xRadius: r, yRadius: r).fill()
            }
        }
    }

    // MARK: Callout / note

    private func drawCallout(_ c: UsageCallout, y: CGFloat) {
        let text = Self.text(c.text, Self.rowFont, .labelColor)
        let symbol = Self.symbolName(for: c.severity) ?? "info.circle.fill"
        let color = c.severity == .normal ? NSColor.secondaryLabelColor : CardPalette.fill(for: c.severity)
        drawSymbol(symbol, color: color, pointSize: 11, leftEdge: contentLeft, centerY: y + text.size().height / 2)
        let textX = contentLeft + Self.iconIndent
        Self.drawTruncated(text, x: textX, y: y, maxWidth: contentRight - textX)
        if let detail = c.detail {
            Self.drawTruncated(Self.text(detail, Self.smallFont, .secondaryLabelColor),
                               x: textX, y: y + 16, maxWidth: contentRight - textX)
        }
    }

    private func drawNote(_ note: String, y: CGFloat) {
        Self.drawTruncated(Self.text(note, Self.smallFont, .secondaryLabelColor), x: contentLeft, y: y, maxWidth: contentW)
    }

    // MARK: Tooltips

    /// Hover text for each chart column. It only repeats what the stat tiles and
    /// peak label already say in words, so a menu that never shows tooltips
    /// loses nothing.
    private func rebuildToolTips() {
        removeAllToolTips()
        toolTipText.removeAll()
        for (block, y) in blockOrigins() {
            guard case .dailyChart(let chart) = block else { continue }
            let (slots, _) = chartColumns(chart, y: y)
            for (i, slot) in slots.enumerated() where chart.tooltips.indices.contains(i) {
                let tag = addToolTip(slot, owner: self, userData: nil)
                toolTipText[tag] = chart.tooltips[i]
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        toolTipText[tag] ?? ""
    }

    // MARK: Text helpers

    private static func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    /// One line, tail-truncated to `maxWidth` rather than clipped mid-glyph.
    private static func drawTruncated(_ str: NSAttributedString, x: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        guard maxWidth > 0 else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let m = NSMutableAttributedString(attributedString: str)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        m.draw(with: NSRect(x: x, y: y, width: maxWidth, height: ceil(m.size().height)),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Menu bar key

/// One-line legend for the Center Dash layout, drawn with the same marks the
/// menu bar uses: two series share one track there, so they need a key.
final class MenuBarKeyView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuCardView.width, height: 20))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11)
        let midY = bounds.midY
        var x = MenuCardView.leading
        func label(_ s: String, _ color: NSColor) {
            let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let size = str.size()
            str.draw(at: NSPoint(x: x, y: midY - size.height / 2))
            x += size.width
        }
        let swatch = NSSize(width: 20, height: 6)
        func track() -> NSRect {
            let r = NSRect(x: x, y: midY - swatch.height / 2, width: swatch.width, height: swatch.height)
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            return r
        }

        label("Menu bar", .secondaryLabelColor)
        x += 10
        let solid = track()
        NSColor.labelColor.withAlphaComponent(0.48).setFill()
        NSBezierPath(roundedRect: NSRect(x: solid.minX, y: solid.minY, width: solid.width * 0.7, height: solid.height),
                     xRadius: 3, yRadius: 3).fill()
        x += swatch.width + 5
        label("weekly", .labelColor)
        x += 12
        let dashed = track()
        NSColor.labelColor.setFill()
        for i in 0..<3 {
            NSBezierPath(roundedRect: NSRect(x: dashed.minX + 1 + CGFloat(i) * 6.5, y: midY - 1, width: 4, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
        x += swatch.width + 5
        label("5-hour", .labelColor)
    }
}
