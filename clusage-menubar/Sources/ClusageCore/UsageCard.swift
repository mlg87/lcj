/// UsageCard.swift — what the dropdown shows, as plain data.
///
/// The dropdown follows the layout dedicated trackers have converged on, with
/// CodexBar as the reference and Claude Usage Tracker / ClaudeBar close behind:
/// a provider header with plan badge and freshness line; one meter per limit
/// with a marker where an even burn would be, the reset countdown plus clock
/// time, and a pace verdict ("On pace" / "14% in reserve" / "Runs out in 2h");
/// then, where local logs make it possible, cost tiles, a daily cost chart and
/// the top models.
///
/// WHY a model in ClusageCore rather than building NSViews directly: every
/// sentence here has edge cases (unknown resets, a limit hit mid-window, a
/// budget that is not a limit) that the test runner can pin without AppKit.
/// MenuCardView only turns these values into pixels.

import Foundation

// MARK: - Model

/// Colour role for a meter or status line. Maps onto the Claude gauge bands.
public enum UsageSeverity: Equatable, Sendable {
    case normal, warning, critical

    public init(_ band: Band) {
        switch band {
        case .ok:       self = .normal
        case .warn:     self = .warning
        case .critical: self = .critical
        }
    }
}

public struct UsageStatusText: Equatable, Sendable {
    public let text: String
    public let severity: UsageSeverity

    public init(_ text: String, _ severity: UsageSeverity) {
        self.text = text
        self.severity = severity
    }
}

/// One limit: title line, bar with pace marker, reset line with pace verdict.
public struct UsageMeter: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    /// "10% used" — the view emphasises the first word.
    public let valueText: String
    /// 0–100 fill; nil draws an empty track ("no data").
    public let fillPercent: Int?
    public let severity: UsageSeverity
    /// Where an even burn would be by now, 0–100; nil hides the marker.
    public let paceMarkerPercent: Double?
    public let detail: String
    public let status: UsageStatusText?

    public init(title: String, subtitle: String?, valueText: String, fillPercent: Int?,
                severity: UsageSeverity, paceMarkerPercent: Double?, detail: String,
                status: UsageStatusText?) {
        self.title = title
        self.subtitle = subtitle
        self.valueText = valueText
        self.fillPercent = fillPercent
        self.severity = severity
        self.paceMarkerPercent = paceMarkerPercent
        self.detail = detail
        self.status = status
    }
}

/// A stat tile: sentence-case label, headline value, small detail.
public struct UsageStat: Equatable, Sendable {
    public let label: String
    public let value: String
    public let detail: String?

    public init(label: String, value: String, detail: String?) {
        self.label = label
        self.value = value
        self.detail = detail
    }
}

/// Daily columns, oldest first with today last (drawn as the emphasis bar).
public struct UsageDailyChart: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let trailing: String?
    public let values: [Double]
    /// One hover line per column.
    public let tooltips: [String]
    public let startLabel: String
    public let endLabel: String
    /// The one direct label on the plot: the tallest column's value.
    public let peakIndex: Int?
    public let peakLabel: String?

    public init(title: String, subtitle: String?, trailing: String?, values: [Double],
                tooltips: [String], startLabel: String, endLabel: String,
                peakIndex: Int?, peakLabel: String?) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.values = values
        self.tooltips = tooltips
        self.startLabel = startLabel
        self.endLabel = endLabel
        self.peakIndex = peakIndex
        self.peakLabel = peakLabel
    }
}

public struct UsageBreakdownRow: Equatable, Sendable {
    public let name: String
    /// 0...1 bar length relative to the largest row.
    public let fraction: Double
    public let value: String

    public init(name: String, fraction: Double, value: String) {
        self.name = name
        self.fraction = fraction
        self.value = value
    }
}

public struct UsageBreakdown: Equatable, Sendable {
    public let title: String
    public let subtitle: String?
    public let rows: [UsageBreakdownRow]

    public init(title: String, subtitle: String?, rows: [UsageBreakdownRow]) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
    }
}

public struct UsageCallout: Equatable, Sendable {
    public let text: String
    public let detail: String?
    public let severity: UsageSeverity

    public init(text: String, detail: String?, severity: UsageSeverity) {
        self.text = text
        self.detail = detail
        self.severity = severity
    }
}

public enum UsageCardBlock: Equatable, Sendable {
    case meter(UsageMeter)
    case stats([UsageStat])
    case dailyChart(UsageDailyChart)
    case breakdown(UsageBreakdown)
    case callout(UsageCallout)
    case note(String)
}

public struct UsageCard: Equatable, Sendable {
    public let provider: Provider
    public let title: String
    /// Plan name ("Business"), when a provider reports one.
    public let badge: String?
    /// "Updated 2m ago"; nil before the first result.
    public let freshness: String?
    public let blocks: [UsageCardBlock]

    public init(provider: Provider, title: String, badge: String?, freshness: String?,
                blocks: [UsageCardBlock]) {
        self.provider = provider
        self.title = title
        self.badge = badge
        self.freshness = freshness
        self.blocks = blocks
    }
}

// MARK: - Text helpers

/// "4h 6m", "6d 8h", "38m": menuBarCountdown with the spaces the dropdown can
/// afford. "<1m" when imminent, "–" when unknown.
public func detailCountdown(to date: Date?, from now: Date = Date()) -> String {
    menuBarCountdown(to: date, from: now)
        .replacingOccurrences(of: #"([dh])(\d)"#, with: "$1 $2", options: .regularExpression)
}

/// A future moment, only as specific as it needs to be: "1:30 PM" later today,
/// "Mon 2:00 PM" within six days, "Oct 12" beyond.
///
/// WHY six days, not seven: a weekly reset one week out lands on today's
/// weekday, and "Thu 1:30 PM" on a Thursday reads as today.
public func resetClockText(_ date: Date, now: Date, calendar: Calendar = .current,
                           locale: Locale = .autoupdatingCurrent) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
        return menuBarTime(date, locale: locale, timeZone: calendar.timeZone)
    }
    if date.timeIntervalSince(now) < 6 * 24 * 3600 {
        return menuDetailTime(date, locale: locale, timeZone: calendar.timeZone)
    }
    return shortDayText(date, calendar: calendar, locale: locale)
}

/// "Resets in 4h 6m · 1:30 PM" — countdown first (it answers "how long?"),
/// clock time second (it answers "is that before my meeting?").
public func resetSentence(_ resetsAt: Date?, now: Date, calendar: Calendar = .current,
                          locale: Locale = .autoupdatingCurrent) -> String {
    guard let resetsAt else { return "Reset time not reported" }
    guard resetsAt.timeIntervalSince(now) >= 60 else { return "Resetting now" }
    return "Resets in \(detailCountdown(to: resetsAt, from: now)) · "
        + resetClockText(resetsAt, now: now, calendar: calendar, locale: locale)
}

/// "just now", "4m ago", "3h ago", "2d ago".
public func relativeAgo(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    guard seconds >= 60 else { return "just now" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}

/// The pace verdict beside a meter's reset line.
///
/// Deficit is reported as its consequence ("Runs out in 2h 10m") rather than
/// "11% in deficit": the two always coincide (above the even line means the
/// average rate empties the limit before the reset), and the run-out time is
/// the half you can act on. The deficit itself is visible on the bar.
public func paceStatus(pace: UsagePace?, usedPercent: Double, limitReached: Bool,
                       now: Date) -> UsageStatusText? {
    if limitReached { return UsageStatusText("Limit reached", .critical) }
    guard let pace, pace.projectedPercent != nil else { return nil }
    let gap = usedPercent - pace.expectedPercent
    if abs(gap) <= paceOnPaceTolerance { return UsageStatusText("On pace", .normal) }
    if gap < 0 { return UsageStatusText("\(Int((-gap).rounded()))% in reserve", .normal) }
    if let out = pace.runsOutAt {
        return UsageStatusText("Runs out in \(detailCountdown(to: out, from: now))", .warning)
    }
    return UsageStatusText("\(Int(gap.rounded()))% in deficit", .warning)
}

/// Degraded-fetch reasons (UsageFetcher's vocabulary) as a headline + next step.
public func claudeFailureText(_ reason: String) -> (title: String, detail: String?) {
    switch reason {
    case "no_cookie": return ("No session cookie", "Choose Settings → Set Session Cookie…")
    case "no_org_id": return ("Org ID not found", "Re-copy the full cookie from claude.ai")
    case "http_401":  return ("Cookie rejected or expired", "Paste a fresh one from claude.ai")
    case "network":   return ("Network error", "Retrying on the next refresh")
    case "http_5xx":  return ("Anthropic API error", "Retrying on the next refresh")
    default:          return ("Unexpected API response", "The usage endpoint may have changed")
    }
}

private func freshnessText(_ updatedAt: Date?, now: Date) -> String? {
    updatedAt.map { "Updated \(relativeAgo($0, now: now))" }
}

private func shortDayText(_ date: Date, calendar: Calendar, locale: Locale) -> String {
    let fmt = DateFormatter()
    fmt.locale = locale
    fmt.timeZone = calendar.timeZone
    fmt.setLocalizedDateFormatFromTemplate("MMMd")
    return fmt.string(from: date)
}

/// A limit bucket as a meter; a missing bucket stays visible as an empty track
/// so the layout doesn't jump when the API omits one for a refresh.
private func limitMeter(title: String, subtitle: String?, bucket: Bucket?,
                        windowLength: TimeInterval, now: Date,
                        calendar: Calendar, locale: Locale) -> UsageMeter {
    guard let b = bucket else {
        return UsageMeter(title: title, subtitle: subtitle, valueText: "–", fillPercent: nil,
                          severity: .normal, paceMarkerPercent: nil,
                          detail: "Not reported", status: nil)
    }
    let pace = usagePace(usedPercent: Double(b.percent), resetsAt: b.resetsAt,
                         windowLength: windowLength, now: now)
    return UsageMeter(
        title: title, subtitle: subtitle, valueText: "\(b.percent)% used",
        fillPercent: b.percent, severity: UsageSeverity(band(forPercent: b.percent)),
        paceMarkerPercent: pace?.expectedPercent,
        detail: resetSentence(b.resetsAt, now: now, calendar: calendar, locale: locale),
        status: paceStatus(pace: pace, usedPercent: Double(b.percent),
                           limitReached: b.percent >= 100, now: now))
}

// MARK: - Claude card

/// The Claude card. `failureReason` wins over `snapshot` (the fetcher never
/// reports both); both nil means the first fetch hasn't landed yet.
public func claudeUsageCard(snapshot: UsageSnapshot?, failureReason: String?, updatedAt: Date?,
                            now: Date, calendar: Calendar = .current,
                            locale: Locale = .autoupdatingCurrent) -> UsageCard {
    var blocks: [UsageCardBlock] = []
    if let failureReason {
        let failure = claudeFailureText(failureReason)
        blocks.append(.callout(UsageCallout(text: failure.title, detail: failure.detail, severity: .warning)))
    } else if let snap = snapshot {
        blocks.append(.meter(limitMeter(title: "Session", subtitle: "5-hour", bucket: snap.session,
                                        windowLength: UsageWindow.fiveHours, now: now,
                                        calendar: calendar, locale: locale)))
        blocks.append(.meter(limitMeter(title: "Weekly", subtitle: "all models", bucket: snap.weeklyAll,
                                        windowLength: UsageWindow.week, now: now,
                                        calendar: calendar, locale: locale)))
        if let scoped = snap.weeklyScoped {
            blocks.append(.meter(limitMeter(title: "Weekly", subtitle: "\(scoped.label.capitalized) only",
                                            bucket: scoped, windowLength: UsageWindow.week, now: now,
                                            calendar: calendar, locale: locale)))
        }
    } else {
        blocks.append(.note("Waiting for first fetch…"))
    }
    return UsageCard(provider: .claude, title: "Claude", badge: nil,
                     freshness: freshnessText(updatedAt, now: now), blocks: blocks)
}

// MARK: - Codex card

/// The Codex card, assembled from the three Codex lanes: the session-log scan
/// (`summary` / `scanFailed`), the ChatGPT spend-control fetch (`plan` /
/// `planFailureReason`) and the personal `budget` used when no limit exists.
public func codexUsageCard(summary: CodexSummary?, scanFailed: Bool,
                           plan: CodexPlanUsage?, planFailureReason: String?,
                           budget: Double, updatedAt: Date?, now: Date,
                           calendar: Calendar = .current,
                           locale: Locale = .autoupdatingCurrent) -> UsageCard {
    var blocks: [UsageCardBlock] = []
    let limits = summary?.limitStatus
    let hasWindows = limits?.primaryUsedPercent != nil || limits?.secondaryUsedPercent != nil

    // Limits first: they are what the menu bar raised the question about.
    if let limits, hasWindows {
        if let p = limits.primaryUsedPercent {
            blocks.append(.meter(limitMeter(
                title: "Session", subtitle: "5-hour",
                bucket: Bucket(percent: p, resetsAt: limits.primaryResetsAt, label: "5H"),
                windowLength: UsageWindow.fiveHours, now: now, calendar: calendar, locale: locale)))
        }
        if let s = limits.secondaryUsedPercent {
            blocks.append(.meter(limitMeter(
                title: "Weekly", subtitle: nil,
                bucket: Bucket(percent: s, resetsAt: limits.secondaryResetsAt, label: "WEEK"),
                windowLength: UsageWindow.week, now: now, calendar: calendar, locale: locale)))
        }
    }
    if let plan {
        blocks.append(.meter(creditsMeter(plan, now: now, calendar: calendar, locale: locale)))
    } else if let summary, !hasWindows {
        blocks.append(.meter(budgetMeter(summary: summary, budget: budget, now: now,
                                         calendar: calendar, locale: locale)))
    }

    // Plan-lane failures that explain why there is no credits meter.
    if plan == nil, let reason = planFailureReason {
        switch reason {
        case "no_token": blocks.append(.note("Sign in with the Codex CLI to show your monthly limit"))
        case "http_401": blocks.append(.note("Codex sign-in expired — run codex once to refresh"))
        default:         break   // no spend control on this plan, or transient — budget meter covers it
        }
    }

    // Log-reported flags, unless the credits meter already says the same thing.
    if let limits, limits.isLimited, plan?.reached != true {
        var reason = "Usage limited"
        if limits.spendControlReached == true { reason = "Org spend control reached" }
        else if let type = limits.rateLimitReachedType { reason = "Rate limit reached (\(type))" }
        else if limits.hasCredits == false { reason = "Out of credits" }
        blocks.append(.callout(UsageCallout(text: reason, detail: "Reported by the latest Codex session",
                                            severity: .critical)))
    } else if let balance = limits?.creditBalance {
        blocks.append(.note("Credits remaining: \(formatCost(balance))"))
    }

    if scanFailed {
        blocks.append(.callout(UsageCallout(text: "Codex usage unavailable",
                                            detail: "The session-log scan failed", severity: .warning)))
    } else if let summary {
        if summary.lastActivity != nil {
            blocks.append(.stats(codexStats(summary)))
            if summary.last30DaysCost > 0, !summary.daily.isEmpty {
                blocks.append(.dailyChart(codexDailyChart(summary, calendar: calendar, locale: locale)))
            }
            if !summary.perModel.isEmpty {
                blocks.append(.breakdown(codexModelBreakdown(summary.perModel)))
            }
        }
        blocks.append(.note(codexActivityNote(summary, now: now)))
        blocks.append(.note("Costs are API-equivalent estimates (standard tier)"))
    } else {
        blocks.append(.note("Waiting for first scan…"))
    }

    let badge = (plan?.planType ?? limits?.planType).map { $0.capitalized }
    return UsageCard(provider: .codex, title: "Codex", badge: badge,
                     freshness: freshnessText(updatedAt, now: now), blocks: blocks)
}

/// ChatGPT spend control. Pace uses the exact credit ratio, not the rounded
/// percent: 4,279 of 4,300 rounds to "100%" but still has hours of runway.
private func creditsMeter(_ plan: CodexPlanUsage, now: Date, calendar: Calendar,
                          locale: Locale) -> UsageMeter {
    let exact = plan.limitCredits > 0 ? plan.usedCredits / plan.limitCredits * 100 : Double(plan.usedPercent)
    let pace = monthlyUsagePace(usedPercent: exact, resetsAt: plan.resetsAt, now: now, calendar: calendar)
    let used = formatTokensLong(Int(plan.usedCredits.rounded()), locale: locale)
    let limit = formatTokensLong(Int(plan.limitCredits.rounded()), locale: locale)
    return UsageMeter(
        title: "Monthly credits", subtitle: "\(used) / \(limit)",
        valueText: "\(plan.usedPercent)% used", fillPercent: plan.usedPercent,
        severity: plan.reached ? .critical : UsageSeverity(band(forPercent: plan.usedPercent)),
        paceMarkerPercent: pace?.expectedPercent,
        detail: resetSentence(plan.resetsAt, now: now, calendar: calendar, locale: locale),
        status: paceStatus(pace: pace, usedPercent: exact, limitReached: plan.reached, now: now))
}

/// The personal budget, used only when OpenAI reports no limit at all. The
/// subtitle says it is a target so it is never read as a provider cap, and the
/// verdict is in dollars because that is the unit the target was chosen in.
private func budgetMeter(summary: CodexSummary, budget: Double, now: Date,
                         calendar: Calendar, locale: Locale) -> UsageMeter {
    let spent = summary.monthToDateCost
    let reset = startOfNextMonth(after: now, calendar: calendar)
    var pace: UsagePace?
    if let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) {
        pace = usagePace(usedPercent: budget > 0 ? spent / budget * 100 : 0,
                         windowStart: monthStart, resetsAt: reset, now: now)
    }
    let severity = UsageSeverity(budgetBand(monthCost: spent, budget: budget))
    let status: UsageStatusText?
    if budget > 0, spent > budget {
        status = UsageStatusText("\(budgetDollars(spent - budget)) over budget", severity)
    } else if budget > 0, let pace, pace.projectedPercent != nil, pace.elapsedFraction > 0 {
        // Dollar projection straight from month-to-date spend, so a month that
        // will overshoot says by how much (the percent projection caps at 100).
        let projected = spent / pace.elapsedFraction
        status = UsageStatusText("~\(budgetDollars(projected)) by month end",
                                 projected > budget ? .warning : .normal)
    } else {
        status = nil
    }
    return UsageMeter(
        title: "Monthly budget", subtitle: "personal target",
        valueText: "\(formatCost(spent)) of \(formatCost(budget))",
        fillPercent: budgetFillPercent(monthCost: spent, budget: budget),
        severity: severity, paceMarkerPercent: pace?.expectedPercent,
        detail: resetSentence(reset, now: now, calendar: calendar, locale: locale),
        status: status)
}

/// Budget verdicts round to whole dollars from $10 up: "$68 over budget" reads
/// as a number, "$68.0 over budget" as a measurement nobody made.
private func budgetDollars(_ dollars: Double) -> String {
    dollars < 10 ? formatCost(dollars) : String(format: "$%.0f", dollars.rounded())
}

private func codexStats(_ s: CodexSummary) -> [UsageStat] {
    func tokens(_ n: Int) -> String { "\(formatTokens(n)) tokens" }
    return [
        UsageStat(label: "Today", value: formatCost(s.todayCost), detail: tokens(s.todayTotal)),
        UsageStat(label: "7 days", value: formatCost(s.last7DaysCost), detail: tokens(s.last7DaysTotal)),
        UsageStat(label: "30 days", value: formatCost(s.last30DaysCost), detail: tokens(s.last30DaysTotal)),
        UsageStat(label: "This month", value: formatCost(s.monthToDateCost), detail: tokens(s.monthToDateTotal)),
    ]
}

private func codexDailyChart(_ s: CodexSummary, calendar: Calendar, locale: Locale) -> UsageDailyChart {
    let values = s.daily.map(\.cost)
    let dayFmt = DateFormatter()
    dayFmt.locale = locale
    dayFmt.timeZone = calendar.timeZone
    dayFmt.setLocalizedDateFormatFromTemplate("EEEMMMd")
    let tooltips = s.daily.map {
        "\(dayFmt.string(from: $0.day)): \(formatCost($0.cost)) · \(formatTokens($0.totalTokens)) tokens"
    }
    let peak = values.indices.max { values[$0] < values[$1] }
    let peakValue = peak.map { values[$0] } ?? 0
    let average = s.last30DaysCost / Double(max(1, values.count))
    return UsageDailyChart(
        title: "Daily cost", subtitle: "last 30 days", trailing: "avg \(formatCost(average))/day",
        values: values, tooltips: tooltips,
        startLabel: s.daily.first.map { shortDayText($0.day, calendar: calendar, locale: locale) } ?? "",
        endLabel: "Today",
        peakIndex: peakValue > 0 ? peak : nil,
        peakLabel: peakValue > 0 ? formatCost(peakValue) : nil)
}

/// Top four models by 7-day cost; the tail folds into one "Other" row rather
/// than growing the menu for every model a session ever touched.
private func codexModelBreakdown(_ models: [CodexModelUsage]) -> UsageBreakdown {
    var rows: [(name: String, cost: Double, tokens: Int)] = models.prefix(4).map {
        ($0.model, $0.cost, $0.totalTokens)
    }
    let tail = models.dropFirst(4)
    if !tail.isEmpty {
        rows.append(("Other (\(tail.count))", tail.reduce(0) { $0 + $1.cost },
                     tail.reduce(0) { $0 + $1.totalTokens }))
    }
    let maxCost = rows.map(\.cost).max() ?? 0
    return UsageBreakdown(title: "Top models", subtitle: "last 7 days", rows: rows.map {
        UsageBreakdownRow(name: $0.name, fraction: maxCost > 0 ? $0.cost / maxCost : 0,
                          value: "\(formatCost($0.cost)) · \(formatTokens($0.tokens))")
    })
}

private func codexActivityNote(_ s: CodexSummary, now: Date) -> String {
    guard let last = s.lastActivity else { return "No Codex activity in the last 30 days" }
    let sessions: String
    switch s.sessionsToday {
    case 0:  sessions = "No sessions today"
    case 1:  sessions = "1 session today"
    default: sessions = "\(s.sessionsToday) sessions today"
    }
    return "\(sessions) · last active \(relativeAgo(last, now: now))"
}
