/// UsagePace.swift — "am I on track for this window?" math for the dropdown.
///
/// Dedicated usage trackers pair each raw percent with two derived facts: where
/// an even burn would have you by now, and when the current burn runs out.
/// CodexBar (github.com/steipete/CodexBar, UsagePace.swift) is the reference:
/// expected = elapsed ÷ window, "on pace" within 2 points, run-out = remaining ÷
/// (used ÷ elapsed), hidden until 3% of the window has passed. Everything falls
/// out of (used %, window start, reset time) — no extra requests, no history.

import Foundation

/// Lengths of the fixed windows the limit APIs report (the monthly window is
/// calendar-based, so it is derived from its reset date instead).
public enum UsageWindow {
    public static let fiveHours: TimeInterval = 5 * 3600
    public static let week: TimeInterval = 7 * 24 * 3600
}

/// Share of a window that must pass before pace is shown. Extrapolating from
/// the first few minutes turns one early burst into "runs out in 20 minutes".
public let paceMinimumElapsedFraction = 0.03
/// |used − expected| at or under this many points reads as "On pace".
public let paceOnPaceTolerance = 2.0

public struct UsagePace: Equatable, Sendable {
    /// 0...1 share of the window already elapsed.
    public let elapsedFraction: Double
    /// Usage an even burn would have reached by now (elapsedFraction × 100) —
    /// where the meter's pace marker sits.
    public let expectedPercent: Double
    /// Usage at the reset if the current average rate holds; nil until
    /// paceMinimumElapsedFraction of the window has passed.
    public let projectedPercent: Double?
    /// When usage reaches 100% at the current rate — set only when that lands
    /// before the reset and the limit isn't already hit.
    public let runsOutAt: Date?

    public init(elapsedFraction: Double, expectedPercent: Double,
                projectedPercent: Double?, runsOutAt: Date?) {
        self.elapsedFraction = elapsedFraction
        self.expectedPercent = expectedPercent
        self.projectedPercent = projectedPercent
        self.runsOutAt = runsOutAt
    }
}

/// Pace for a window running from `windowStart` to `resetsAt`. `usedPercent` is
/// a Double so callers with an exact ratio (credits used ÷ limit) don't lose the
/// last fraction of a point to rounding — at 99.5% that fraction is the answer.
/// nil when the reset is unknown, already past, or the window is degenerate.
public func usagePace(usedPercent: Double, windowStart: Date, resetsAt: Date?, now: Date) -> UsagePace? {
    guard let resetsAt else { return nil }
    let length = resetsAt.timeIntervalSince(windowStart)
    guard length > 0, now < resetsAt else { return nil }

    // A reset further out than one window (clock skew, or a reset the API moved)
    // pins the window at its start rather than going negative.
    let elapsed = min(length, max(0, now.timeIntervalSince(windowStart)))
    let fraction = elapsed / length
    let used = max(0, min(100, usedPercent))

    var projected: Double?
    var runsOut: Date?
    if elapsed > 0, fraction >= paceMinimumElapsedFraction {
        projected = used / fraction
        if used > 0, used < 100, used / fraction > 100 {
            runsOut = now.addingTimeInterval((100 - used) / (used / elapsed))
        }
    }
    return UsagePace(elapsedFraction: fraction, expectedPercent: fraction * 100,
                     projectedPercent: projected, runsOutAt: runsOut)
}

/// Pace for a fixed-length window that ends at `resetsAt`.
public func usagePace(usedPercent: Double, resetsAt: Date?, windowLength: TimeInterval, now: Date) -> UsagePace? {
    guard let resetsAt else { return nil }
    return usagePace(usedPercent: usedPercent, windowStart: resetsAt.addingTimeInterval(-windowLength),
                     resetsAt: resetsAt, now: now)
}

/// Pace for a calendar-month window that ends at `resetsAt` (Codex monthly
/// credits: the previous reset is one calendar month earlier, so a February
/// window is shorter than an August one).
public func monthlyUsagePace(usedPercent: Double, resetsAt: Date?, now: Date,
                             calendar: Calendar = .current) -> UsagePace? {
    guard let resetsAt,
          let start = calendar.date(byAdding: .month, value: -1, to: resetsAt)
    else { return nil }
    return usagePace(usedPercent: usedPercent, windowStart: start, resetsAt: resetsAt, now: now)
}
