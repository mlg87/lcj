/// ClusageTests/main.swift — assertion-based test runner.
///
/// WHY not XCTest/swift-testing: both require the full Xcode toolchain; CLT-only
/// Swift installations don't provide `import XCTest` or `import Testing`. A plain
/// executable target that exit(1)s on failure integrates cleanly with `make test`
/// and CI without any framework dependency.

import ClusageCore
import Foundation

// MARK: - Test harness

// nonisolated(unsafe): top-level vars in main.swift are @MainActor in Swift 6;
// test helpers are nonisolated. Safe here — test runner is single-threaded.
nonisolated(unsafe) var failures = 0

func expect(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond {
        failures += 1
        print("FAIL [\(URL(fileURLWithPath: file).lastPathComponent):\(line)]: \(msg)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String, file: String = #file, line: Int = #line) {
    if a != b {
        failures += 1
        print("FAIL [\(URL(fileURLWithPath: file).lastPathComponent):\(line)]: \(msg) — got \(a), expected \(b)")
    }
}

// MARK: - Fixtures

/// Full live API response captured 2026-07-10 from the claude.ai org-usage endpoint
/// (GET /api/organizations/{orgId}/usage). Response shape matches the previous internal
/// endpoint — UsageSnapshot.parse works unchanged (verified against ClaudeUsageBar's
/// parser, 2026-07-10). This fixture pins the real shape so parse changes break visibly.
let fullLiveFixture = """
{
  "five_hour": {"utilization": 9.0, "resets_at": "2026-07-11T02:00:00.156578+00:00"},
  "seven_day": {"utilization": 12.0, "resets_at": "2026-07-14T19:00:00.156597+00:00"},
  "seven_day_opus": null,
  "limits": [
    {"kind": "session",       "group": "session", "percent": 9,  "severity": "normal", "resets_at": "2026-07-11T02:00:00.156578+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_all",    "group": "weekly",  "percent": 12, "severity": "normal", "resets_at": "2026-07-14T19:00:00.156597+00:00", "scope": null, "is_active": true},
    {"kind": "weekly_scoped", "group": "weekly",  "percent": 5,  "severity": "normal", "resets_at": "2026-07-14T19:00:00.156863+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
  ]
}
"""

/// Fixture without `limits` but with five_hour / seven_day (fallback path).
let fallbackFixture = """
{
  "five_hour": {"utilization": 42.0, "resets_at": "2026-07-11T02:00:00+00:00"},
  "seven_day": {"utilization": 78.0, "resets_at": "2026-07-14T19:00:00+00:00"}
}
"""


// MARK: - Tests: UsageSnapshot.parse

func testFullLiveFixture() {
    let data = fullLiveFixture.data(using: .utf8)!
    let snap = UsageSnapshot.parse(data)
    expect(snap != nil, "Full live fixture: parse returned nil")
    guard let snap else { return }

    // session
    expect(snap.session != nil, "Full fixture: session should be non-nil")
    expectEqual(snap.session?.percent, 9, "Full fixture: session percent")
    expectEqual(snap.session?.label, "5H", "Full fixture: session label")
    expect(snap.session?.resetsAt != nil, "Full fixture: session resetsAt non-nil")

    // weeklyScoped
    expect(snap.weeklyScoped != nil, "Full fixture: weeklyScoped should be non-nil")
    expectEqual(snap.weeklyScoped?.percent, 5, "Full fixture: weeklyScoped percent")
    expectEqual(snap.weeklyScoped?.label, "FABLE", "Full fixture: weeklyScoped label (uppercased)")
    expect(snap.weeklyScoped?.resetsAt != nil, "Full fixture: weeklyScoped resetsAt non-nil")

    // weeklyAll
    expect(snap.weeklyAll != nil, "Full fixture: weeklyAll should be non-nil")
    expectEqual(snap.weeklyAll?.percent, 12, "Full fixture: weeklyAll percent")
    expectEqual(snap.weeklyAll?.label, "WEEK", "Full fixture: weeklyAll label")
    expect(snap.weeklyAll?.resetsAt != nil, "Full fixture: weeklyAll resetsAt non-nil")
}

func testParseResetDate() {
    // The 6-digit fractional-second string from the live fixture.
    let iso = "2026-07-11T02:00:00.156578+00:00"
    let date = parseResetDate(iso)
    expect(date != nil, "parseResetDate: returned nil for live fixture string")
    // Verify epoch — 2026-07-11T02:00:00Z = 1783735200
    // (= 2026-01-01 1767225600 + 191*86400 + 7200; 1752199200 is 2025-07-11, one year early)
    if let d = date {
        let expected = Date(timeIntervalSince1970: 1783735200)
        expect(abs(d.timeIntervalSince(expected)) < 1, "parseResetDate: epoch mismatch — got \(d.timeIntervalSince1970), expected 1783735200")
    }
}

func testFallbackFixture() {
    let data = fallbackFixture.data(using: .utf8)!
    let snap = UsageSnapshot.parse(data)
    expect(snap != nil, "Fallback fixture: parse returned nil")
    guard let snap else { return }
    expectEqual(snap.session?.percent, 42, "Fallback: session percent")
    expectEqual(snap.weeklyAll?.percent, 78, "Fallback: weeklyAll percent")
    expect(snap.weeklyScoped == nil, "Fallback: weeklyScoped should be nil")
}

func testBadShapeFixtures() {
    // Empty object — no five_hour, no limits
    let empty = "{}".data(using: .utf8)!
    expect(UsageSnapshot.parse(empty) == nil, "bad_shape: empty object should return nil")

    // Non-JSON garbage
    let garbage = "not json".data(using: .utf8)!
    expect(UsageSnapshot.parse(garbage) == nil, "bad_shape: garbage should return nil")

    // limits[] present but empty (and no fallback fields) → nil
    let emptyLimits = #"{"limits":[]}"#.data(using: .utf8)!
    expect(UsageSnapshot.parse(emptyLimits) == nil, "bad_shape: empty limits with no fallback → nil")
}

func testPercentClamping() {
    let fixture = #"""
    {"limits":[
      {"kind":"session","percent":250,"resets_at":null},
      {"kind":"weekly_all","percent":-5,"resets_at":null}
    ]}
    """#.data(using: .utf8)!
    let snap = UsageSnapshot.parse(fixture)
    expect(snap != nil, "Clamping: parse returned nil")
    expectEqual(snap?.session?.percent, 100, "Clamping: 250 should clamp to 100")
    expectEqual(snap?.weeklyAll?.percent, 0, "Clamping: -5 should clamp to 0")

    // Fractional percent (9.6 → 10)
    let fracFixture = #"""
    {"limits":[{"kind":"session","percent":9.6,"resets_at":null},{"kind":"weekly_all","percent":12,"resets_at":null}]}
    """#.data(using: .utf8)!
    let fracSnap = UsageSnapshot.parse(fracFixture)
    expectEqual(fracSnap?.session?.percent, 10, "Clamping: 9.6 should round to 10")
}

// MARK: - Tests: CookieAuth

func testSanitizeCookie() {
    // Passthrough — no label, no whitespace
    expectEqual(sanitizeCookie("a=1; b=2"), "a=1; b=2", "sanitizeCookie: passthrough")

    // Trim leading/trailing whitespace and newlines
    expectEqual(sanitizeCookie("  a=1\n"), "a=1", "sanitizeCookie: trims whitespace")

    // Strip "Cookie:" header label (with space) — case-insensitive
    expectEqual(sanitizeCookie("Cookie: a=1"), "a=1", "sanitizeCookie: strips 'Cookie: ' label")
    expectEqual(sanitizeCookie("cookie:a=1"), "a=1", "sanitizeCookie: strips 'cookie:' label case-insensitively")
}

func testOrgIdFromCookie() {
    // Mid-string with spaces after semicolons
    expectEqual(
        orgId(fromCookie: "anthropic-device-id=x; lastActiveOrg=1234-abcd; sessionKey=sk-ant"),
        "1234-abcd",
        "orgId: mid-string extraction"
    )

    // Absent key → nil
    expect(
        orgId(fromCookie: "sessionKey=sk-ant") == nil,
        "orgId: absent key should return nil"
    )

    // Empty value → nil
    expect(
        orgId(fromCookie: "lastActiveOrg=; sessionKey=x") == nil,
        "orgId: empty value should return nil"
    )
}

// MARK: - Tests: menuBarTime

func testMenuBarTime() {
    // nil → "–:–"
    expectEqual(menuBarTime(nil), "–:–", "menuBarTime(nil)")

    // Fixed date: 2026-07-13T01:00:00Z = 1783728000
    // In America/New_York (UTC-4 in July) that's 2026-07-12 21:00 local (9:00 PM)
    let date = Date(timeIntervalSince1970: 1783728000)
    let nyTZ = TimeZone(identifier: "America/New_York")!

    let en_US = Locale(identifier: "en_US")
    let usResult = menuBarTime(date, locale: en_US, timeZone: nyTZ)
    expect(usResult.contains("PM") || usResult.contains("pm"),
           "menuBarTime: en_US should produce 12h format containing PM, got: \(usResult)")

    let en_GB = Locale(identifier: "en_GB")
    let gbResult = menuBarTime(date, locale: en_GB, timeZone: nyTZ)
    expect(!gbResult.contains("AM") && !gbResult.contains("PM") && !gbResult.contains("am") && !gbResult.contains("pm"),
           "menuBarTime: en_GB should produce 24h format without AM/PM, got: \(gbResult)")
}

// MARK: - Tests: band

func testBand() {
    expectEqual(band(forPercent: 0),   .ok,       "band(0)=ok")
    expectEqual(band(forPercent: 69),  .ok,       "band(69)=ok")
    expectEqual(band(forPercent: 70),  .warn,     "band(70)=warn")
    expectEqual(band(forPercent: 89),  .warn,     "band(89)=warn")
    expectEqual(band(forPercent: 90),  .critical, "band(90)=critical")
    expectEqual(band(forPercent: 100), .critical, "band(100)=critical")
}

// MARK: - Tests: menuBarShortLabel

func testMenuBarShortLabel() {
    expectEqual(menuBarShortLabel("5H"), "5H", "5H stays 5H")
    expectEqual(menuBarShortLabel("WEEK"), "WK", "WEEK abbreviates to WK")
    expectEqual(menuBarShortLabel("FABLE"), "F",  "FABLE maps to F")
    expectEqual(menuBarShortLabel("op"), "OP", "short labels are uppercased")
    expectEqual(menuBarShortLabel("  "), "–", "blank label falls back to dash")
}

// MARK: - Tests: RefreshInterval

func testRefreshIntervalNormalize() {
    for m in RefreshInterval.allowedMinutes {
        expectEqual(RefreshInterval.normalize(m), m, "allowed value \(m) passes through")
    }
    expectEqual(RefreshInterval.normalize(0), 5, "absent (0) falls back to default")
    expectEqual(RefreshInterval.normalize(4), 5, "disallowed value falls back to default")
    expectEqual(RefreshInterval.normalize(-1), 5, "negative falls back to default")
    expectEqual(RefreshInterval.defaultMinutes, 5, "default stays the historical 5-min cadence")
}

// MARK: - Tests: Codex session-log parsing

/// Real `token_count` line captured 2026-08-26 from ~/.codex/sessions.
let codexTokenCountLine = """
{"timestamp":"2026-08-26T19:34:25.107Z","ordinal":23,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":65477,"cached_input_tokens":46592,"cache_write_input_tokens":0,"output_tokens":317,"reasoning_output_tokens":64,"total_tokens":65794},"last_token_usage":{"input_tokens":33183,"cached_input_tokens":31488,"cache_write_input_tokens":0,"output_tokens":118,"reasoning_output_tokens":18,"total_tokens":33301},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null}}}
"""

func testParseCodexTokenCountLine() {
    guard let turn = parseCodexTokenCountLine(codexTokenCountLine) else {
        expect(false, "codex: real token_count line should parse")
        return
    }
    expectEqual(turn.inputTokens, 33183, "codex: input from last_token_usage (per-turn delta, not cumulative)")
    expectEqual(turn.cachedInputTokens, 31488, "codex: cached input")
    expectEqual(turn.outputTokens, 118, "codex: output")
    expectEqual(turn.totalTokens, 33301, "codex: total")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    expectEqual(utc.component(.hour, from: turn.timestamp), 19, "codex: timestamp parsed with fractional seconds")

    expect(parseCodexTokenCountLine("{\"type\":\"session_meta\",\"payload\":{}}") == nil,
           "codex: non-token_count line returns nil")
    expect(parseCodexTokenCountLine("{not json") == nil, "codex: malformed JSON returns nil")
    expect(parseCodexTokenCountLine(
        "{\"timestamp\":\"2026-08-26T19:34:25.107Z\",\"payload\":{\"type\":\"token_count\",\"info\":null}}") == nil,
           "codex: token_count with null info returns nil")

    let noFraction = """
    {"timestamp":"2026-08-26T19:34:25Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"total_tokens":15}}}}
    """
    expectEqual(parseCodexTokenCountLine(noFraction)?.totalTokens, 15,
                "codex: timestamp without fractional seconds still parses")
}

func testParseCodexModelAndLimitLines() {
    let turnContextLine = """
    {"timestamp":"2026-08-26T19:50:02.480Z","type":"turn_context","payload":{"turn_id":"x","cwd":"/tmp","model":"gpt-5.6-luna","approval_policy":"never"}}
    """
    expectEqual(parseCodexModelLine(turnContextLine), "gpt-5.6-luna", "codex: model from turn_context")
    expect(parseCodexModelLine(codexTokenCountLine) == nil, "codex: token_count line yields no model")

    let sessionMetaLine = """
    {"timestamp":"2026-08-26T09:26:33.000Z","type":"session_meta","payload":{"session_id":"x","base_instructions":{"text":"...","provenance":{"model":"gpt-5.6-luna"}}}}
    """
    expectEqual(parseCodexModelLine(sessionMetaLine), "gpt-5.6-luna",
                "codex: model from session_meta base_instructions.provenance (ambient sessions)")

    let healthy = """
    {"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"credits":{"has_credits":true,"unlimited":false,"balance":null},"spend_control_reached":null,"plan_type":"business","rate_limit_reached_type":null}}}
    """
    if let limit = parseCodexLimitStatus(healthy) {
        expectEqual(limit.planType, "business", "codex: plan type parsed")
        expectEqual(limit.hasCredits, true, "codex: has_credits parsed")
        expect(limit.creditBalance == nil, "codex: null balance stays nil")
        expect(!limit.isLimited, "codex: healthy status is not limited")
    } else {
        expect(false, "codex: limit status parses from real-shaped rate_limits")
    }

    let limited = """
    {"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"credits":{"has_credits":false},"spend_control_reached":true,"rate_limit_reached_type":"credits_exhausted","primary":{"used_percent":97.6,"reset_at":1788220801},"secondary":{"used_percent":43.2,"reset_at":1788307201}}}}
    """
    if let status = parseCodexLimitStatus(limited) {
        expect(status.isLimited, "codex: spend control / exhausted credits flag as limited")
        expectEqual(status.primaryUsedPercent, 98, "codex: primary used_percent rounded")
        expectEqual(status.primaryResetsAt, Date(timeIntervalSince1970: 1788220801),
                    "codex: primary reset parsed")
        expectEqual(status.secondaryUsedPercent, 43, "codex: secondary used_percent rounded")
        expectEqual(status.secondaryResetsAt, Date(timeIntervalSince1970: 1788307201),
                    "codex: secondary reset parsed")
    } else {
        expect(false, "codex: limited status parses")
    }

    let cliSpelling = """
    {"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1788220801}}}}
    """
    expectEqual(parseCodexLimitStatus(cliSpelling)?.primaryResetsAt, Date(timeIntervalSince1970: 1788220801),
                "codex: resets_at (CLI spelling) parses like reset_at")
}

// MARK: - Tests: Codex aggregation + pricing

/// Fixed clock for the window tests: 2026-08-26 14:00 in America/Denver.
func codexTestCalendar() -> (cal: Calendar, now: Date) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Denver")!
    let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 14))!
    return (cal, now)
}

func testAggregateCodexUsage() {
    let (cal, now) = codexTestCalendar()
    func turn(daysAgo: Int, hour: Int, total: Int, output: Int) -> CodexTurn {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        let ts = cal.date(byAdding: .hour, value: hour, to: day)!
        return CodexTurn(timestamp: ts, inputTokens: total - output, cachedInputTokens: 0,
                         outputTokens: output, totalTokens: total)
    }

    let sessions: [String: [CodexTurn]] = [
        "a.jsonl": [turn(daysAgo: 0, hour: 9, total: 1000, output: 100),
                    turn(daysAgo: 0, hour: 10, total: 2000, output: 200)],
        "b.jsonl": [turn(daysAgo: 3, hour: 12, total: 5000, output: 500)],
        "c.jsonl": [turn(daysAgo: 6, hour: 8, total: 700, output: 70)],    // oldest in-7d-window day
        "d.jsonl": [turn(daysAgo: 7, hour: 8, total: 9999, output: 999)],  // outside 7d, inside 30d
        "e.jsonl": [turn(daysAgo: 27, hour: 8, total: 111, output: 11)],   // Jul 30: inside 30d, before month start
        "f.jsonl": [turn(daysAgo: 40, hour: 8, total: 5555, output: 55)],  // outside every window
    ]

    let summary = aggregateCodexUsage(turnsBySession: sessions, now: now, calendar: cal)
    expectEqual(summary.todayTotal, 3000, "codex agg: today sums both turns of session a")
    expectEqual(summary.todayOutput, 300, "codex agg: today output")
    expectEqual(summary.last7DaysTotal, 8700, "codex agg: 7-day window includes day-6, excludes day-7")
    expectEqual(summary.last7DaysOutput, 870, "codex agg: 7-day output")
    expectEqual(summary.last30DaysTotal, 18810, "codex agg: 30-day window adds day-7 and day-27, excludes day-40")
    // now = Aug 26 → month starts Aug 1: excludes day-27 (Jul 30) but includes day-7 (Aug 19).
    expectEqual(summary.monthToDateTotal, 18699, "codex agg: month-to-date starts at calendar month start")
    expectEqual(summary.sessionsToday, 1, "codex agg: only session a active today")
    expectEqual(summary.lastActivity, sessions["a.jsonl"]![1].timestamp, "codex agg: lastActivity is newest turn")

    let empty = aggregateCodexUsage(turnsBySession: [:], now: now, calendar: cal)
    expectEqual(empty.todayTotal, 0, "codex agg: empty input → zero totals")
    expect(empty.lastActivity == nil, "codex agg: empty input → nil lastActivity")
}

func testCodexPricing() {
    let (cal, now) = codexTestCalendar()

    // Assert the RESOLUTION contract against the table, not against literal
    // prices: re-pinning constants here would break the suite on every
    // legitimate price update without testing any behaviour.
    expectEqual(codexPricing(forModel: "gpt-5.6-luna"), codexPricingTable["gpt-5.6-luna"]!,
                "codex pricing: exact table hit")
    expectEqual(codexPricing(forModel: "gpt-5.6-luna-2026-09-01"), codexPricingTable["gpt-5.6-luna"]!,
                "codex pricing: prefix match on dated variant")
    expectEqual(codexPricing(forModel: "codex-auto-review"), codexFallbackPricing, "codex pricing: unknown model → fallback")
    expectEqual(codexPricing(forModel: nil), codexFallbackPricing, "codex pricing: nil model → fallback")

    // Ambiguous prefix: this name matches BOTH "gpt-5.4-mini" and "gpt-5.4".
    // Dictionary iteration order is randomized per process, so a first-match
    // scan returned either one depending on the launch (a 3.3x price swing);
    // longest-match-wins is deterministic by construction.
    expectEqual(codexPricing(forModel: "gpt-5.4-mini-2026-08-01"), codexPricingTable["gpt-5.4-mini"]!,
                "codex pricing: ambiguous prefix resolves to the longest match")
    expectEqual(codexPricing(forModel: "gpt-5.4-2026-08-01"), codexPricingTable["gpt-5.4"]!,
                "codex pricing: shorter prefix still resolves when it is the longest match")

    // 1M uncached input + 1M cached + 1M output on luna: 0.20 + 0.02 + 1.20 = 1.42
    let lunaTurn = CodexTurn(timestamp: now, inputTokens: 2_000_000, cachedInputTokens: 1_000_000,
                             outputTokens: 1_000_000, totalTokens: 3_000_000, model: "gpt-5.6-luna")
    expect(abs(costOfCodexTurn(lunaTurn) - 1.42) < 0.0001, "codex cost: luna uncached/cached/output split")

    let solTurn = CodexTurn(timestamp: now, inputTokens: 500_000, cachedInputTokens: 0,
                            outputTokens: 100_000, totalTokens: 600_000, model: "gpt-5.6-sol")
    expect(abs(costOfCodexTurn(solTurn) - 4.0) < 0.0001, "codex cost: sol (0.5M×$4 + 0.1M×$20 = $4)")

    let degenTurn = CodexTurn(timestamp: now, inputTokens: 0, cachedInputTokens: 0,
                              outputTokens: 0, totalTokens: 1_000_000, model: "gpt-5.6-luna")
    expect(abs(costOfCodexTurn(degenTurn) - 0.20) < 0.0001,
           "codex cost: component-less total priced at input rate (ambient sessions)")

    let costSummary = aggregateCodexUsage(turnsBySession: ["s.jsonl": [lunaTurn, solTurn]], now: now, calendar: cal)
    expect(abs(costSummary.todayCost - 5.42) < 0.0001, "codex cost: aggregate today cost sums turns")
    expectEqual(costSummary.perModel.count, 2, "codex cost: per-model breakdown has both models")
    expectEqual(costSummary.perModel.first?.model, "gpt-5.6-sol", "codex cost: per-model sorted by cost desc")
}

func testBudgetBarometer() {
    expectEqual(budgetBand(monthCost: 79, budget: 100), .ok, "budget: under budget → green")
    expectEqual(budgetBand(monthCost: 100, budget: 100), .ok, "budget: at budget → green")
    expectEqual(budgetBand(monthCost: 150, budget: 100), .warn, "budget: 1-2x budget → yellow")
    expectEqual(budgetBand(monthCost: 201, budget: 100), .critical, "budget: over 2x budget → red")
    expectEqual(budgetBand(monthCost: 999, budget: 0), .ok, "budget: zero budget never alarms")
    expectEqual(budgetFillPercent(monthCost: 79, budget: 100), 79, "budget: fill percent = cost/budget")
    expectEqual(budgetFillPercent(monthCost: 250, budget: 100), 100, "budget: fill capped at 100")
}

func testFormatCostAndTokens() {
    expectEqual(formatCost(0), "$0.00", "formatCost: zero")
    expectEqual(formatCost(3.456), "$3.46", "formatCost: under $10 two decimals")
    expectEqual(formatCost(12.34), "$12.3", "formatCost: under $100 one decimal")
    expectEqual(formatCost(123.4), "$123", "formatCost: over $100 whole dollars")

    expectEqual(formatTokens(0), "0", "formatTokens: zero")
    expectEqual(formatTokens(950), "950", "formatTokens: sub-thousand stays raw")
    expectEqual(formatTokens(1_500), "1.5K", "formatTokens: thousands one decimal")
    expectEqual(formatTokens(12_345), "12.3K", "formatTokens: tens of thousands")
    expectEqual(formatTokens(123_456), "123K", "formatTokens: hundreds of thousands drop decimal")
    expectEqual(formatTokens(3_456_789), "3.5M", "formatTokens: millions")
    expectEqual(formatTokens(21_000_000), "21M", "formatTokens: trailing .0 dropped")
    expectEqual(formatTokens(1_234_567_890), "1.2B", "formatTokens: billions")
    // Pin the locale: a bare NumberFormatter follows Locale.current, so this
    // would fail on a de_DE machine ("3.456.789") against a green patch.
    expectEqual(formatTokensLong(3_456_789, locale: Locale(identifier: "en_US")), "3,456,789",
                "formatTokensLong: grouped (en_US)")
    expectEqual(formatTokensLong(3_456_789, locale: Locale(identifier: "de_DE")), "3.456.789",
                "formatTokensLong: grouping follows the injected locale")
}

// MARK: - Tests: Codex plan usage (ChatGPT spend control)

func testCodexPlanUsageParse() {
    let whamBody = """
    {"user_id":"user-x","plan_type":"business","rate_limit":null,
     "credits":{"has_credits":true,"unlimited":false,"balance":null},
     "spend_control":{"reached":false,"individual_limit":{
       "source":"workspace_spend_controls",
       "limit":"4300","used":"3604.349905371666","remaining":"695.650094628334",
       "used_percent":84,"remaining_percent":16,
       "reset_after_seconds":380033,"reset_at":1788220801}}}
    """.data(using: .utf8)!
    if let plan = CodexPlanUsage.parse(whamBody) {
        expectEqual(plan.usedPercent, 84, "plan: used_percent parsed")
        expect(abs(plan.limitCredits - 4300) < 0.001, "plan: string limit parsed to Double")
        expect(abs(plan.usedCredits - 3604.3499) < 0.001, "plan: string used parsed")
        expect(abs(plan.remainingCredits - 695.6501) < 0.001, "plan: string remaining parsed")
        expectEqual(plan.resetsAt, Date(timeIntervalSince1970: 1788220801), "plan: reset_at epoch parsed")
        expect(!plan.reached, "plan: reached false")
        expectEqual(plan.planType, "business", "plan: top-level plan_type parsed for the dropdown badge")
    } else {
        expect(false, "plan: real wham/usage body parses")
    }

    expect(CodexPlanUsage.parse("{\"plan_type\":\"business\",\"spend_control\":null}".data(using: .utf8)!) == nil,
           "plan: null spend_control → nil (fall back to budget)")
    expect(CodexPlanUsage.parse("{}".data(using: .utf8)!) == nil, "plan: empty body → nil")

    let numericBody = """
    {"spend_control":{"reached":true,"individual_limit":{"limit":100,"used":100}}}
    """.data(using: .utf8)!
    if let capped = CodexPlanUsage.parse(numericBody) {
        expectEqual(capped.usedPercent, 100, "plan: percent derived when used_percent absent")
        expect(capped.reached, "plan: reached true propagates")
    } else {
        expect(false, "plan: numeric credits also parse")
    }
}

func testMenuBarShortDate() {
    let (cal, _) = codexTestCalendar()
    let resetDate = cal.date(from: DateComponents(year: 2026, month: 8, day: 31))!
    expectEqual(menuBarShortDate(resetDate, locale: Locale(identifier: "en_US"), timeZone: cal.timeZone),
                "8/31", "menuBarShortDate: en_US month/day")
    expectEqual(menuBarShortDate(nil), "–", "menuBarShortDate: nil date dashes")
}

// MARK: - Tests: Remaining-capacity layout helpers

func testMenuBarCountdown() {
    let (_, now) = codexTestCalendar()
    func inSecs(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }
    expectEqual(menuBarCountdown(to: nil, from: now), "–", "countdown: nil → dash")
    expectEqual(menuBarCountdown(to: inSecs(30), from: now), "<1m", "countdown: under a minute")
    expectEqual(menuBarCountdown(to: inSecs(-100), from: now), "<1m", "countdown: past date clamps")
    expectEqual(menuBarCountdown(to: inSecs(38 * 60), from: now), "38m", "countdown: minutes only")
    expectEqual(menuBarCountdown(to: inSecs(2 * 3600 + 14 * 60), from: now), "2h14m", "countdown: hours + minutes")
    expectEqual(menuBarCountdown(to: inSecs(3 * 3600), from: now), "3h", "countdown: whole hours drop minutes")
    expectEqual(menuBarCountdown(to: inSecs(4 * 86400 + 9 * 3600 + 30 * 60), from: now), "4d9h",
                "countdown: days + hours, minutes dropped")
    expectEqual(menuBarCountdown(to: inSecs(5 * 86400 + 20 * 60), from: now), "5d", "countdown: whole days drop hours")
}

func testStartOfNextMonth() {
    let (cal, now) = codexTestCalendar()   // 2026-08-26 14:00 Denver
    let next = startOfNextMonth(after: now, calendar: cal)
    expectEqual(next, cal.date(from: DateComponents(year: 2026, month: 9, day: 1)), "next month: Sep 1 local midnight")
    let dec = cal.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23))!
    expectEqual(startOfNextMonth(after: dec, calendar: cal),
                cal.date(from: DateComponents(year: 2027, month: 1, day: 1)), "next month: year rollover")
}

func testMenuBarStyleNormalize() {
    expectEqual(MenuBarStyle.normalize(nil), .grid, "style: absent → grid (pre-existing layout)")
    expectEqual(MenuBarStyle.normalize("bogus"), .grid, "style: unknown → grid")
    expectEqual(MenuBarStyle.normalize("remaining"), .remaining, "style: remaining round-trips")
    expectEqual(MenuBarStyle.normalize("centerDash"), .centerDash, "style: center dash round-trips")
    expectEqual(MenuBarStyle.defaultStyle, .grid, "style: default stays the historical grid")
}

// MARK: - Tests: provider visibility

func testProviderVisibilityDefaults() {
    expect(ProviderVisibility.both.isVisible(.claude) && ProviderVisibility.both.isVisible(.codex),
           "visibility: .both shows both providers")
    expectEqual(ProviderVisibility.normalize(claude: true, codex: true), .both,
                "visibility: both stored on round-trips")
    expectEqual(ProviderVisibility.normalize(claude: true, codex: false), .claudeOnly,
                "visibility: Claude-only round-trips")
    expectEqual(ProviderVisibility.normalize(claude: false, codex: true),
                ProviderVisibility(claude: false, codex: true), "visibility: Codex-only round-trips")
    // Impossible state (hand-edited defaults) repairs to the app's original behaviour.
    expectEqual(ProviderVisibility.normalize(claude: false, codex: false), .claudeOnly,
                "visibility: neither visible repairs to Claude-only")
}

func testProviderVisibilityToggling() {
    let both = ProviderVisibility.both
    expect(both.canToggle(.claude) && both.canToggle(.codex), "visibility: with both on, either may be hidden")
    expectEqual(both.toggling(.claude), ProviderVisibility(claude: false, codex: true),
                "visibility: hiding Claude leaves Codex")
    expectEqual(both.toggling(.codex), .claudeOnly, "visibility: hiding Codex leaves Claude")

    // The last visible provider cannot be hidden — the menu disables that item.
    let claudeOnly = ProviderVisibility.claudeOnly
    expect(!claudeOnly.canToggle(.claude), "visibility: last provider (Claude) cannot be hidden")
    expect(claudeOnly.toggling(.claude) == nil, "visibility: hiding the last provider returns nil")
    expect(claudeOnly.canToggle(.codex), "visibility: the hidden provider can always be turned back on")
    expectEqual(claudeOnly.toggling(.codex), .both, "visibility: turning Codex back on restores both")

    let codexOnly = ProviderVisibility(claude: false, codex: true)
    expect(!codexOnly.canToggle(.codex), "visibility: last provider (Codex) cannot be hidden")
    expectEqual(codexOnly.toggling(.claude), .both, "visibility: turning Claude back on restores both")
}

// MARK: - Tests: window edge cases

/// Windows are built with Calendar arithmetic rather than 86_400-second math, so
/// they must survive a DST transition. America/Denver falls back on 2026-11-01.
func testSevenDayWindowCrossesDST() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Denver")!
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14))!

    func turn(_ date: Date, _ total: Int) -> CodexTurn {
        CodexTurn(timestamp: date, inputTokens: total, cachedInputTokens: 0,
                  outputTokens: 0, totalTokens: total)
    }
    // Window start is local midnight 6 days back: 2026-10-28 00:00 MDT.
    let insideEdge = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 0, minute: 30))!
    let outsideEdge = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 23, minute: 30))!
    let summary = aggregateCodexUsage(
        turnsBySession: ["a.jsonl": [turn(insideEdge, 100), turn(outsideEdge, 900)]],
        now: now, calendar: cal)
    expectEqual(summary.last7DaysTotal, 100,
                "DST: 7-day window starts at local midnight 6 days back, not now minus 7x86400")
    expectEqual(summary.last30DaysTotal, 1000, "DST: both turns are inside the 30-day window")
}

/// month-to-date on the 1st: only today counts, even though the 30-day window
/// still reaches back into the previous month.
func testMonthToDateOnFirstOfMonth() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Denver")!
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 0, minute: 30))!

    func turn(_ date: Date, _ total: Int) -> CodexTurn {
        CodexTurn(timestamp: date, inputTokens: total, cachedInputTokens: 0,
                  outputTokens: 0, totalTokens: total)
    }
    let thisMonth = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 0, minute: 10))!
    let lastMonth = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 23, minute: 50))!
    let summary = aggregateCodexUsage(
        turnsBySession: ["a.jsonl": [turn(thisMonth, 10), turn(lastMonth, 500)]],
        now: now, calendar: cal)
    expectEqual(summary.monthToDateTotal, 10, "MTD on the 1st excludes 10 minutes earlier in the previous month")
    expectEqual(summary.last30DaysTotal, 510, "the 30-day window still includes the previous month")
    expectEqual(summary.todayTotal, 10, "today starts at local midnight")
}

/// A clock-skewed or mis-stamped future line must not count anywhere — and must
/// not advertise recent activity while every window reads zero.
func testFutureDatedTurnIsIgnored() {
    let (cal, now) = codexTestCalendar()
    let future = cal.date(byAdding: .hour, value: 3, to: now)!
    let summary = aggregateCodexUsage(
        turnsBySession: ["a.jsonl": [
            CodexTurn(timestamp: future, inputTokens: 999, cachedInputTokens: 0,
                      outputTokens: 999, totalTokens: 999)]],
        now: now, calendar: cal)
    expectEqual(summary.todayTotal, 0, "future turn excluded from today")
    expectEqual(summary.last30DaysTotal, 0, "future turn excluded from every window")
    expect(summary.lastActivity == nil, "future turn does not set lastActivity")
}

/// A limits-only token_count event (payload.info null) still reports rate_limits.
func testLimitsOnlyLineStillReportsLimits() {
    let limitsOnly = """
    {"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"plan_type":"business","spend_control_reached":true}}}
    """
    guard let parsed = parseCodexLine(limitsOnly) else {
        expect(false, "limits-only token_count line parses")
        return
    }
    expect(parsed.turn == nil, "limits-only line yields no turn")
    expectEqual(parsed.limitStatus?.spendControlReached, true, "limits-only line still reports spend_control_reached")
    expect(parsed.limitStatus?.isLimited == true, "limits-only line flags as limited")
}

/// Defensive branches in the spend-control parser: malformed and out-of-range
/// values must degrade rather than surface a wrong gauge.
func testCodexPlanUsageDefensiveBranches() {
    // Grouped numerals are not Double-parseable; nil means "fall back to budget".
    expect(CodexPlanUsage.parse(#"{"spend_control":{"individual_limit":{"limit":"4,300","used":"100"}}}"#
        .data(using: .utf8)!) == nil, "plan: grouped numeral limit degrades to nil rather than a wrong number")

    if let zero = CodexPlanUsage.parse(#"{"spend_control":{"individual_limit":{"limit":0,"used":50}}}"#
        .data(using: .utf8)!) {
        expectEqual(zero.usedPercent, 0, "plan: zero limit never divides by zero")
        expect(zero.remainingCredits == 0, "plan: remaining floors at zero when used exceeds limit")
    } else {
        expect(false, "plan: zero limit still parses")
    }

    if let over = CodexPlanUsage.parse(#"{"spend_control":{"individual_limit":{"limit":100,"used":250,"used_percent":250}}}"#
        .data(using: .utf8)!) {
        expectEqual(over.usedPercent, 100, "plan: out-of-range used_percent clamps to 100")
    } else {
        expect(false, "plan: over-limit body still parses")
    }
}

// MARK: - Tests: dropdown (daily series, pace, cards)

/// en_US time formats put U+202F before AM/PM; compare against plain spaces.
func plainSpaces(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

func testCodexDailySeries() {
    let (cal, now) = codexTestCalendar()   // 2026-08-26 14:00 Denver
    func turn(daysAgo: Int, hour: Int, total: Int) -> CodexTurn {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        return CodexTurn(timestamp: cal.date(byAdding: .hour, value: hour, to: day)!, inputTokens: total,
                         cachedInputTokens: 0, outputTokens: 0, totalTokens: total)
    }
    let summary = aggregateCodexUsage(turnsBySession: ["a.jsonl": [
        turn(daysAgo: 0, hour: 9, total: 100), turn(daysAgo: 0, hour: 1, total: 50),
        turn(daysAgo: 29, hour: 3, total: 7), turn(daysAgo: 30, hour: 3, total: 999)]],
        now: now, calendar: cal)
    expectEqual(summary.daily.count, 30, "daily: one entry per day of the 30-day window")
    expectEqual(summary.daily.last?.totalTokens, 150, "daily: today's turns land in the last entry")
    expectEqual(summary.daily.first?.totalTokens, 7, "daily: 29 days back is the first entry; 30 is outside")
    expectEqual(summary.daily.first?.day, cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now)),
                "daily: entries start at local midnight")
    expectEqual(summary.daily.map(\.totalTokens).reduce(0, +), summary.last30DaysTotal,
                "daily: entries sum to the 30-day total")
    expect(aggregateCodexUsage(turnsBySession: [:], now: now, calendar: cal).daily.allSatisfy { $0.totalTokens == 0 },
           "daily: no turns still yields a zero-filled series")
}

/// The fall-back day is 25 hours long; a late turn on it must not slide into
/// the next day the way 86_400-second bucketing would.
func testCodexDailySeriesAcrossDST() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Denver")!
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14))!
    let late = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30))!
    let summary = aggregateCodexUsage(turnsBySession: ["a.jsonl": [
        CodexTurn(timestamp: late, inputTokens: 5, cachedInputTokens: 0, outputTokens: 0, totalTokens: 5)]],
        now: now, calendar: cal)
    expectEqual(summary.daily.firstIndex { $0.totalTokens == 5 }, 27,
                "daily DST: 23:30 on Nov 1 stays on Nov 1 (index 27; Nov 3 is 29)")
}

func testUsagePace() {
    let (cal, now) = codexTestCalendar()
    // 5h window with 1h left: 80% elapsed.
    guard let pace = usagePace(usedPercent: 40, resetsAt: now.addingTimeInterval(3600),
                               windowLength: UsageWindow.fiveHours, now: now) else {
        expect(false, "pace: computes for a live window")
        return
    }
    expect(abs(pace.elapsedFraction - 0.8) < 1e-9, "pace: elapsed share from reset minus window length")
    expect(abs(pace.expectedPercent - 80) < 1e-9, "pace: even-burn point = elapsed share")
    expect(abs((pace.projectedPercent ?? 0) - 50) < 1e-9, "pace: projection = used ÷ elapsed share")
    expect(pace.runsOutAt == nil, "pace: no run-out while the projection stays under 100")

    // 60% after 1h of 5h: the remaining 40% goes in 40 minutes at that rate.
    let hot = usagePace(usedPercent: 60, resetsAt: now.addingTimeInterval(4 * 3600),
                        windowLength: UsageWindow.fiveHours, now: now)
    expectEqual(hot?.runsOutAt, now.addingTimeInterval(40 * 60), "pace: run-out = remaining ÷ (used ÷ elapsed)")
    expect(usagePace(usedPercent: 100, resetsAt: now.addingTimeInterval(3600), windowLength: UsageWindow.fiveHours,
                     now: now)?.runsOutAt == nil, "pace: no run-out once the limit is already hit")

    // 1h into a week is under the 3% floor: marker yes, projection no.
    let early = usagePace(usedPercent: 5, resetsAt: now.addingTimeInterval(UsageWindow.week - 3600),
                          windowLength: UsageWindow.week, now: now)
    expect(early != nil && early?.projectedPercent == nil, "pace: no projection before 3% of the window")

    expect(usagePace(usedPercent: 50, resetsAt: nil, windowLength: UsageWindow.week, now: now) == nil,
           "pace: unknown reset → nil")
    expect(usagePace(usedPercent: 50, resetsAt: now.addingTimeInterval(-60), windowLength: UsageWindow.week,
                     now: now) == nil, "pace: past reset → nil")
    expectEqual(usagePace(usedPercent: 10, resetsAt: now.addingTimeInterval(2 * UsageWindow.week),
                          windowLength: UsageWindow.week, now: now)?.elapsedFraction, 0,
                "pace: a reset beyond one window pins elapsed at zero instead of going negative")

    // Monthly window is calendar-based: Jul 31 14:00 → Aug 31 14:00 is 31 days.
    let monthlyReset = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 14))!
    let monthly = monthlyUsagePace(usedPercent: 50, resetsAt: monthlyReset, now: now, calendar: cal)
    expect(abs((monthly?.elapsedFraction ?? 0) - 26.0 / 31.0) < 1e-9,
           "pace: monthly window starts one calendar month before its reset")
}

func testPaceStatusWording() {
    let (_, now) = codexTestCalendar()
    func pace(_ expected: Double, projected: Double?, runsOut: Date? = nil) -> UsagePace {
        UsagePace(elapsedFraction: expected / 100, expectedPercent: expected,
                  projectedPercent: projected, runsOutAt: runsOut)
    }
    expectEqual(paceStatus(pace: pace(50, projected: 102), usedPercent: 51, limitReached: false, now: now),
                UsageStatusText("On pace", .normal), "pace text: within 2 points reads On pace")
    expectEqual(paceStatus(pace: pace(50, projected: 72), usedPercent: 36, limitReached: false, now: now),
                UsageStatusText("14% in reserve", .normal), "pace text: under the even line reports the reserve")
    expectEqual(paceStatus(pace: pace(40, projected: 150, runsOut: now.addingTimeInterval(2 * 3600 + 10 * 60)),
                           usedPercent: 60, limitReached: false, now: now),
                UsageStatusText("Runs out in 2h 10m", .warning), "pace text: over the line says when it runs out")
    expectEqual(paceStatus(pace: nil, usedPercent: 100, limitReached: true, now: now),
                UsageStatusText("Limit reached", .critical), "pace text: a hit limit wins over pace")
    expect(paceStatus(pace: pace(1, projected: nil), usedPercent: 3, limitReached: false, now: now) == nil,
           "pace text: silent before a projection exists")
}

func testDropdownTimeText() {
    let (cal, now) = codexTestCalendar()   // Wed 2026-08-26 14:00 Denver
    let en = Locale(identifier: "en_US")
    expectEqual(detailCountdown(to: now.addingTimeInterval(2 * 3600 + 14 * 60), from: now), "2h 14m",
                "detail countdown: spaced units")
    expectEqual(detailCountdown(to: now.addingTimeInterval(4 * 86400 + 9 * 3600), from: now), "4d 9h",
                "detail countdown: days and hours")
    expectEqual(detailCountdown(to: now.addingTimeInterval(38 * 60), from: now), "38m", "detail countdown: minutes")

    let tonight = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 18, minute: 30))!
    expectEqual(plainSpaces(resetClockText(tonight, now: now, calendar: cal, locale: en)), "6:30 PM",
                "clock text: later today is the time alone")
    let monday = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 14))!
    expectEqual(plainSpaces(resetClockText(monday, now: now, calendar: cal, locale: en)), "Mon 2:00 PM",
                "clock text: within six days adds the weekday")
    let nextWed = cal.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 13))!
    expectEqual(resetClockText(nextWed, now: now, calendar: cal, locale: en), "Sep 2",
                "clock text: a week out uses the date, so a Wednesday reset can't read as today")
    expectEqual(plainSpaces(resetSentence(tonight, now: now, calendar: cal, locale: en)),
                "Resets in 4h 30m · 6:30 PM", "reset sentence: countdown, then clock time")
    expectEqual(resetSentence(nil, now: now), "Reset time not reported", "reset sentence: unknown reset")
    expectEqual(resetSentence(now.addingTimeInterval(20), now: now), "Resetting now", "reset sentence: imminent")

    expectEqual(relativeAgo(now.addingTimeInterval(-30), now: now), "just now", "ago: under a minute")
    expectEqual(relativeAgo(now.addingTimeInterval(-4 * 60), now: now), "4m ago", "ago: minutes")
    expectEqual(relativeAgo(now.addingTimeInterval(-3 * 3600), now: now), "3h ago", "ago: hours")
    expectEqual(relativeAgo(now.addingTimeInterval(-50 * 3600), now: now), "2d ago", "ago: days")
}

func meters(_ card: UsageCard) -> [UsageMeter] {
    card.blocks.compactMap { if case .meter(let m) = $0 { return m } else { return nil } }
}

func testClaudeUsageCard() {
    let (cal, now) = codexTestCalendar()
    let en = Locale(identifier: "en_US")
    let snap = UsageSnapshot(
        session: Bucket(percent: 10, resetsAt: now.addingTimeInterval(4 * 3600), label: "5H"),
        weeklyScoped: Bucket(percent: 22, resetsAt: now.addingTimeInterval(4 * 86400), label: "FABLE"),
        weeklyAll: Bucket(percent: 32, resetsAt: now.addingTimeInterval(4 * 86400), label: "WEEK"))
    let card = claudeUsageCard(snapshot: snap, failureReason: nil, updatedAt: now.addingTimeInterval(-120),
                               now: now, calendar: cal, locale: en)
    expectEqual(card.freshness, "Updated 2m ago", "claude card: freshness line")
    let m = meters(card)
    expectEqual(m.map(\.title), ["Session", "Weekly", "Weekly"], "claude card: session, weekly, model-scoped week")
    expectEqual(m.map { $0.subtitle ?? "" }, ["5-hour", "all models", "Fable only"], "claude card: subtitles name the window")
    expectEqual(m.first?.valueText, "10% used", "claude card: value reads percent used, like claude.ai")
    // 1h into the 5h window: 10% used against 20% expected.
    expectEqual(m.first?.status, UsageStatusText("10% in reserve", .normal), "claude card: session pace verdict")
    expect(abs((m.first?.paceMarkerPercent ?? 0) - 20) < 1e-9, "claude card: marker at the even-burn point")

    let noScoped = claudeUsageCard(snapshot: UsageSnapshot(session: snap.session, weeklyScoped: nil,
                                                           weeklyAll: snap.weeklyAll),
                                   failureReason: nil, updatedAt: now, now: now)
    expectEqual(meters(noScoped).count, 2, "claude card: no model-scoped bucket, no third meter")

    let failed = claudeUsageCard(snapshot: nil, failureReason: "http_401", updatedAt: now, now: now)
    expectEqual(failed.blocks, [.callout(UsageCallout(text: "Cookie rejected or expired",
                                                      detail: "Paste a fresh one from claude.ai", severity: .warning))],
                "claude card: a failed fetch is one callout with the next step")
    let waiting = claudeUsageCard(snapshot: nil, failureReason: nil, updatedAt: nil, now: now)
    expect(waiting.freshness == nil, "claude card: no freshness before the first fetch")
    expectEqual(waiting.blocks, [.note("Waiting for first fetch…")], "claude card: waiting note")
}

func testCodexUsageCard() {
    let (cal, now) = codexTestCalendar()   // 2026-08-26 14:00 Denver
    let en = Locale(identifier: "en_US")
    func summary(inputTokens: Int) -> CodexSummary {
        aggregateCodexUsage(turnsBySession: ["a.jsonl": [
            CodexTurn(timestamp: now.addingTimeInterval(-3600), inputTokens: inputTokens, cachedInputTokens: 0,
                      outputTokens: 0, totalTokens: inputTokens, model: "gpt-5.6-sol")]],
            now: now, calendar: cal)
    }
    func has(_ card: UsageCard, _ match: (UsageCardBlock) -> Bool) -> Bool { card.blocks.contains(where: match) }
    let light = summary(inputTokens: 1_000_000)
    let reset = cal.date(byAdding: .day, value: 5, to: now)!

    // 4,279 of 4,300 rounds to 100% but is not reached: pace works from the exact ratio.
    let nearly = CodexPlanUsage(limitCredits: 4300, usedCredits: 4279, remainingCredits: 21, usedPercent: 100,
                                resetsAt: reset, reached: false, planType: "business")
    let card = codexUsageCard(summary: light, scanFailed: false, plan: nearly, planFailureReason: nil, budget: 100,
                              updatedAt: now, now: now, calendar: cal, locale: en)
    expectEqual(card.badge, "Business", "codex card: plan badge")
    guard let credits = meters(card).first else {
        expect(false, "codex card: credits meter present")
        return
    }
    expectEqual(credits.title, "Monthly credits", "codex card: credits meter leads")
    expectEqual(credits.subtitle, "4,279 / 4,300", "codex card: exact credits beside the title")
    expectEqual(credits.severity, .critical, "codex card: 100% is critical")
    expect(credits.status?.text.hasPrefix("Runs out in") == true,
           "codex card: 99.5% used projects a run-out instead of claiming the limit is hit, got \(credits.status?.text ?? "nil")")
    expect(has(card) { if case .stats = $0 { return true }; return false }, "codex card: cost tiles")
    expect(has(card) { if case .dailyChart = $0 { return true }; return false }, "codex card: daily chart")
    expect(has(card) { if case .breakdown = $0 { return true }; return false }, "codex card: top models")

    let reached = CodexPlanUsage(limitCredits: 4300, usedCredits: 4300, remainingCredits: 0, usedPercent: 100,
                                 resetsAt: reset, reached: true)
    let blocked = codexUsageCard(summary: light, scanFailed: false, plan: reached, planFailureReason: nil,
                                 budget: 100, updatedAt: now, now: now, calendar: cal, locale: en)
    expectEqual(meters(blocked).first?.status, UsageStatusText("Limit reached", .critical),
                "codex card: a reached spend control says so")

    // No spend control: the personal budget, labelled as a target.
    let budget = codexUsageCard(summary: light, scanFailed: false, plan: nil, planFailureReason: "no_spend_control",
                                budget: 100, updatedAt: now, now: now, calendar: cal, locale: en)
    expectEqual(meters(budget).first?.title, "Monthly budget", "codex card: budget meter without a limit")
    expectEqual(meters(budget).first?.subtitle, "personal target", "codex card: budget says it is not a provider cap")
    // 50M sol input tokens ≈ $200 against a $150 target.
    let over = codexUsageCard(summary: summary(inputTokens: 50_000_000), scanFailed: false, plan: nil,
                              planFailureReason: nil, budget: 150, updatedAt: now, now: now, calendar: cal, locale: en)
    expectEqual(meters(over).first?.status?.text, "$50 over budget", "codex card: overshoot in whole dollars")

    let failed = codexUsageCard(summary: nil, scanFailed: true, plan: nil, planFailureReason: "no_token",
                                budget: 100, updatedAt: now, now: now)
    expect(failed.blocks.contains(.note("Sign in with the Codex CLI to show your monthly limit")),
           "codex card: a missing token explains the absent credits meter")
    expect(has(failed) { if case .callout(let c) = $0 { return c.text == "Codex usage unavailable" }; return false },
           "codex card: scan failure callout")
}

// MARK: - Run all tests

print("Running ClusageTests…")
testFullLiveFixture()
testParseResetDate()
testFallbackFixture()
testBadShapeFixtures()
testPercentClamping()
testSanitizeCookie()
testOrgIdFromCookie()
testMenuBarTime()
testBand()
testMenuBarShortLabel()
testRefreshIntervalNormalize()
testParseCodexTokenCountLine()
testParseCodexModelAndLimitLines()
testAggregateCodexUsage()
testCodexPricing()
testBudgetBarometer()
testFormatCostAndTokens()
testCodexPlanUsageParse()
testMenuBarShortDate()
testMenuBarCountdown()
testStartOfNextMonth()
testMenuBarStyleNormalize()
testProviderVisibilityDefaults()
testProviderVisibilityToggling()
testSevenDayWindowCrossesDST()
testMonthToDateOnFirstOfMonth()
testFutureDatedTurnIsIgnored()
testLimitsOnlyLineStillReportsLimits()
testCodexPlanUsageDefensiveBranches()
testCodexDailySeries()
testCodexDailySeriesAcrossDST()
testUsagePace()
testPaceStatusWording()
testDropdownTimeText()
testClaudeUsageCard()
testCodexUsageCard()

if failures == 0 {
    print("OK — all tests passed")
    exit(0)
} else {
    print("\(failures) failure(s)")
    exit(1)
}
