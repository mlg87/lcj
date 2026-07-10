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

/// Full live API response captured 2026-07-10. This is the ground-truth fixture;
/// it pins the real response shape so parse changes break visibly.
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

/// mcpOAuth-only blob — mirrors the real "unknown" account item found in keychain
/// (account owns only an mcp token, not the Claude AI oauth token we need).
let mcpOnlyBlob = """
{"mcpOAuth":{"clientId":"test-client","scopes":["mcp"]}}
"""

/// Good claudeAiOauth blob — mirrors the real "masongoetz" account item.
let goodBlob = """
{"claudeAiOauth":{"accessToken":"sk-ant-test-token","refreshToken":"rt-test","expiresAt":9999999999000,"scopes":["user:inference"],"subscriptionType":"claude_pro","rateLimitTier":"standard"}}
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

// MARK: - Tests: parseOAuthBlob

func testParseOAuthBlob() {
    // Valid blob
    let (tok, exp) = parseOAuthBlob(goodBlob)
    expectEqual(tok, "sk-ant-test-token", "parseOAuthBlob: token")
    expect(exp != nil, "parseOAuthBlob: expiresAtMs non-nil")

    // mcpOAuth-only blob → (nil, nil)
    let (tok2, exp2) = parseOAuthBlob(mcpOnlyBlob)
    expect(tok2 == nil, "parseOAuthBlob: mcpOnly blob should yield nil token")
    expect(exp2 == nil, "parseOAuthBlob: mcpOnly blob should yield nil expiry")

    // expiresAt in seconds (e.g. 2_000_000_000) → coerced ×1000
    let secondsBlob = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":2000000000}}"#
    let (_, expMs) = parseOAuthBlob(secondsBlob)
    expectEqual(expMs, 2_000_000_000_000, "parseOAuthBlob: seconds-valued expiresAt should be coerced ×1000")

    // Small sentinel (e.g. 5) → NOT coerced (below secondsFloor)
    let smallBlob = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":5}}"#
    let (_, expSmall) = parseOAuthBlob(smallBlob)
    expectEqual(expSmall, 5, "parseOAuthBlob: tiny sentinel should not be coerced")
}

// MARK: - Tests: selectKeychainBlob

func testSelectKeychainBlob() {
    let store: [String: String] = [
        "unknown":    mcpOnlyBlob,
        "masongoetz": goodBlob,
    ]
    let accounts = ["unknown", "masongoetz"]

    // preferAccount matches the good item → returns goodBlob
    let result1 = selectKeychainBlob(accounts: accounts, preferAccount: "masongoetz", read: { store[$0] })
    expectEqual(result1, goodBlob, "selectKeychainBlob: preferred account should win")

    // preferAccount missing → falls through in order → finds masongoetz
    let result2 = selectKeychainBlob(accounts: accounts, preferAccount: "other", read: { store[$0] })
    expectEqual(result2, goodBlob, "selectKeychainBlob: scan fallback should find good blob")

    // Only mcpOnly items → nil
    let result3 = selectKeychainBlob(accounts: ["a"], preferAccount: "a", read: { _ in mcpOnlyBlob })
    expect(result3 == nil, "selectKeychainBlob: no valid blobs → nil")

    // Laziness: "masongoetz" preferred → "unknown" (mcpOnly) must NEVER be read.
    // WHY: each per-item read may trigger a macOS ACL prompt; avoid spurious prompts.
    nonisolated(unsafe) var readAccounts: [String] = []
    let result4 = selectKeychainBlob(accounts: accounts, preferAccount: "masongoetz") { account in
        readAccounts.append(account)
        return store[account]
    }
    expectEqual(result4, goodBlob, "selectKeychainBlob: laziness — preferred wins")
    expect(!readAccounts.contains("unknown"), "selectKeychainBlob: laziness — mcpOnly item must not be read")
}

// MARK: - Tests: resolveToken precedence

func testResolveTokenPrecedence() {
    let nowMs: Int64 = 1_000_000_000_000   // 2001-09-09, well in the past
    let keychainStore: [String: String] = ["masongoetz": goodBlob]

    // env beats file beats keychain
    let envResult = resolveToken(
        env: ["CLAUDE_CODE_OAUTH_TOKEN": "env-token"],
        credentialsFileText: goodBlob,
        keychainAccounts: ["masongoetz"],
        keychainRead: { keychainStore[$0] },
        preferAccount: "masongoetz",
        nowMs: nowMs
    )
    expectEqual(envResult.source, "env", "resolveToken: env should take priority")
    expectEqual(envResult.token, "env-token", "resolveToken: env token value")

    // file beats keychain (no env)
    let fileResult = resolveToken(
        env: [:],
        credentialsFileText: goodBlob,
        keychainAccounts: [],
        keychainRead: { _ in nil },
        preferAccount: "masongoetz",
        nowMs: nowMs
    )
    expectEqual(fileResult.source, "file", "resolveToken: file beats keychain")

    // keychain fallback
    let keychainResult = resolveToken(
        env: [:],
        credentialsFileText: nil,
        keychainAccounts: ["masongoetz"],
        keychainRead: { keychainStore[$0] },
        preferAccount: "masongoetz",
        nowMs: nowMs
    )
    expectEqual(keychainResult.source, "keychain", "resolveToken: keychain fallback")

    // expired token → reason "expired", token nil
    let expiredBlob = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1000}}"#
    // 1000ms expiresAt << nowMs = 1e12ms → expired
    let expiredResult = resolveToken(
        env: [:],
        credentialsFileText: expiredBlob,
        keychainAccounts: [],
        keychainRead: { _ in nil },
        preferAccount: "masongoetz",
        nowMs: nowMs
    )
    expectEqual(expiredResult.reason, "expired", "resolveToken: expired reason")
    expect(expiredResult.token == nil, "resolveToken: expired token should be nil")
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

// MARK: - Run all tests

print("Running ClusageTests…")
testFullLiveFixture()
testParseResetDate()
testFallbackFixture()
testBadShapeFixtures()
testPercentClamping()
testParseOAuthBlob()
testSelectKeychainBlob()
testResolveTokenPrecedence()
testMenuBarTime()
testBand()

if failures == 0 {
    print("OK — all tests passed")
    exit(0)
} else {
    print("\(failures) failure(s)")
    exit(1)
}
