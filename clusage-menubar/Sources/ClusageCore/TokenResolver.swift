/// TokenResolver.swift — resolve the Claude Code OAuth token from where Claude Code stores it.
///
/// WHY local token (not a claude.ai cookie): Clusage reuses the same token Claude
/// Code's own /usage uses; zero manual setup for the user. See README compliance note —
/// undocumented endpoint, degrades gracefully to unavailable on every failure.
///
/// SECURITY: the raw token value is never logged and never returned on a failure path.
/// TokenResult carries only whether a live token was found, its source, and a machine
/// reason — safe to log/diagnose.
///
/// Port of clud/plugin/token_resolver.py with one critical addition: the two-phase
/// Keychain read (see WHY comment on keychainBlob). The errSecParam(-50) failure from
/// bulk secret export forced a split into:
///   1. keychainAccounts — attrs-only enumeration (no secrets, no user prompt)
///   2. keychainBlob    — per-item secret fetch (triggers one-time "Always Allow" ACL)
/// selectKeychainBlob is lazy: it stops at the first item whose blob yields a token,
/// so the mcpOAuth-only "unknown" item is never read (and never prompts) when the
/// preferred "masongoetz" item resolves successfully.

import Foundation
import Security

private let keychainService = "Claude Code-credentials"
private let credentialsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/.credentials.json")

// seconds-coercion guard — same constants as clud's token_resolver.py
private let msThreshold:    Int64 = 1_000_000_000_000  // values >= this are already ms
private let secondsFloor:   Int64 = 1_000_000_000       // plausible epoch-seconds lower bound

// MARK: - Public API

/// Result of a token resolution attempt.
public struct TokenResult: Equatable, Sendable {
    /// The access token, or nil on failure.
    public let token: String?
    /// Where the token came from: "env" | "file" | "keychain" | "none".
    public let source: String
    /// nil on success; "no_token" | "expired" on failure.
    public let reason: String?

    public init(token: String?, source: String, reason: String?) {
        self.token = token
        self.source = source
        self.reason = reason
    }
}

// MARK: - Pure / testable core

/// Extract (accessToken, expiresAt_ms) from a credentials JSON blob.
///
/// Shape: {"claudeAiOauth": {"accessToken": "...", "expiresAt": <epoch ms>}}.
/// Returns (nil, nil) for any malformed input — mirrors clud's _parse_oauth_blob.
public func parseOAuthBlob(_ text: String) -> (token: String?, expiresAtMs: Int64?) {
    guard let data = text.data(using: .utf8),
          let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = doc["claudeAiOauth"] as? [String: Any]
    else { return (nil, nil) }

    let tokenVal = oauth["accessToken"] as? String
    let token: String? = (tokenVal?.isEmpty == false) ? tokenVal : nil

    var expiresAtMs: Int64?
    if let expiresNum = oauth["expiresAt"] as? NSNumber {
        let raw = expiresNum.int64Value
        // Guard: coerce seconds→ms only when value is a plausible epoch-seconds timestamp
        // in [1e9, 1e12). Smaller values (e.g. test sentinels) are taken as-is so a
        // clearly-past timestamp still reads as expired rather than inflated into the future.
        if raw >= secondsFloor && raw < msThreshold {
            expiresAtMs = raw * 1000
        } else {
            expiresAtMs = raw
        }
    }

    return (token, expiresAtMs)
}

/// Ordered lazy selection: preferAccount first, then remaining accounts in enumeration
/// order; the first blob whose parseOAuthBlob yields a token wins.
///
/// WHY lazy (not eager): the mcpOAuth-only "unknown" item must never be read when the
/// preferred "masongoetz" item is good — each per-item fetch may prompt the user via
/// the macOS ACL dialog (bound to the app's code signature). Fetching needlessly would
/// both waste a prompt and slow startup.
///
/// `read` is injected so this function stays pure and testable: in production it calls
/// keychainBlob(account:); in tests it's a closure backed by a dict.
public func selectKeychainBlob(
    accounts: [String],
    preferAccount: String,
    read: (String) -> String?
) -> String? {
    var order = accounts
    if let i = order.firstIndex(of: preferAccount) {
        order.remove(at: i)
        order.insert(preferAccount, at: 0)
    }
    for account in order {
        guard let blob = read(account) else { continue }
        if parseOAuthBlob(blob).token != nil { return blob }
    }
    return nil
}

/// Resolve a live OAuth token from injected sources — fully testable offline.
///
/// Priority: env → credentials file → keychain.
/// Re-call this on every fetch so token rotations by Claude Code are picked up
/// automatically (same discipline as clud's resolve_token).
///
/// keychainAccounts is the list of account names returned by the attrs-only query.
/// keychainRead is a closure that fetches a single item's secret blob by account name.
/// Separating enumeration from data fetch is required because kSecMatchLimitAll +
/// kSecReturnData fails with errSecParam(-50) on macOS (verified live 2026-07-10).
public func resolveToken(
    env: [String: String],
    credentialsFileText: String?,
    keychainAccounts: [String],
    keychainRead: (String) -> String?,
    preferAccount: String,
    nowMs: Int64
) -> TokenResult {
    // 1. Environment variable — highest priority, no expiry check (used by tests/CI).
    if let envTok = env["CLAUDE_CODE_OAUTH_TOKEN"], !envTok.isEmpty {
        return TokenResult(token: envTok, source: "env", reason: nil)
    }

    // 2. Credentials file: ~/.claude/.credentials.json
    var token: String?
    var expiresAtMs: Int64?
    var source = "none"

    if let fileText = credentialsFileText {
        let (t, e) = parseOAuthBlob(fileText)
        if t != nil {
            token = t
            expiresAtMs = e
            source = "file"
        }
    }

    // 3. Keychain: enumerate account names, prefer current username, lazy per-item fetch.
    if token == nil {
        if let blob = selectKeychainBlob(
            accounts: keychainAccounts,
            preferAccount: preferAccount,
            read: keychainRead
        ) {
            let (t, e) = parseOAuthBlob(blob)
            if t != nil {
                token = t
                expiresAtMs = e
                source = "keychain"
            }
        }
    }

    guard let tok = token else {
        return TokenResult(token: nil, source: "none", reason: "no_token")
    }
    if let exp = expiresAtMs, exp <= nowMs {
        return TokenResult(token: nil, source: source, reason: "expired")
    }
    return TokenResult(token: tok, source: source, reason: nil)
}

// MARK: - Impure shell (used by the app)

/// Enumerate account names for the service via attrs-only query.
///
/// WHY no kSecReturnData: kSecMatchLimitAll + kSecReturnData fails with errSecParam(-50)
/// on macOS — bulk secret export is not supported for generic passwords (verified live
/// 2026-07-10). Attributes-only enumeration returns status 0 with all items. Secrets
/// are fetched per-item by keychainBlob(account:).
///
/// Never triggers the macOS "Always Allow" ACL prompt (no data requested).
/// Returns [] on any error.
func keychainAccounts(service: String = keychainService) -> [String] {
    let query: [CFString: Any] = [
        kSecClass:            kSecClassGenericPassword,
        kSecAttrService:      service,
        kSecMatchLimit:       kSecMatchLimitAll,
        kSecReturnAttributes: true,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let items = result as? [[CFString: Any]]
    else { return [] }

    return items.compactMap { item in
        item[kSecAttrAccount] as? String
    }
}

/// Fetch ONE item's secret as a UTF-8 string, or nil.
///
/// WHY per-item: see keychainAccounts. A per-item query (kSecMatchLimitOne +
/// kSecAttrAccount + kSecReturnData) succeeds where the bulk query fails.
/// First call with a given code signature may trigger the one-time macOS ACL prompt;
/// "Always Allow" persists until the binary is rebuilt (new ad-hoc signature).
func keychainBlob(service: String = keychainService, account: String) -> String? {
    let query: [CFString: Any] = [
        kSecClass:        kSecClassGenericPassword,
        kSecAttrService:  service,
        kSecAttrAccount:  account,
        kSecMatchLimit:   kSecMatchLimitOne,
        kSecReturnData:   true,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let blob = String(data: data, encoding: .utf8)
    else { return nil }
    return blob
}

/// Live token resolution using the real environment, credentials file, and Keychain.
///
/// Injecting NSUserName() as preferAccount picks the correct keychain item on machines
/// where multiple items share the "Claude Code-credentials" service (verified on dev machine).
public func resolveTokenLive() -> TokenResult {
    let env = ProcessInfo.processInfo.environment
    let fileText = try? String(contentsOf: credentialsPath, encoding: .utf8)
    let accounts = keychainAccounts()
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    return resolveToken(
        env: env,
        credentialsFileText: fileText,
        keychainAccounts: accounts,
        keychainRead: { keychainBlob(account: $0) },
        preferAccount: NSUserName(),
        nowMs: nowMs
    )
}
