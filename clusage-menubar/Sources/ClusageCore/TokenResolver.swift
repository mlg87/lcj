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
/// Port of clud/plugin/token_resolver.py with one critical addition: the multi-item
/// Keychain selection fix (two items share "Claude Code-credentials" on this machine —
/// one is mcpOAuth-only, the other has claudeAiOauth; we must enumerate all and pick
/// the right one rather than grabbing the first via `security find-generic-password -w`).

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

/// Given a list of (account, blob) pairs from the Keychain, return the blob string
/// whose `parseOAuthBlob` yields a non-nil token.
///
/// WHY multi-item selection: on the target machine TWO generic-password items share
/// service "Claude Code-credentials" — account "unknown" (blob: mcpOAuth only) and
/// account "masongoetz" (blob: claudeAiOauth with accessToken). The `security
/// find-generic-password -w` approach (as used by clud) grabs whichever the OS picks
/// first, which is the wrong one here. We enumerate all items and prefer the account
/// matching the current username, then fall through by insertion order.
public func selectKeychainBlob(
    _ items: [(account: String, blob: String)],
    preferAccount: String
) -> String? {
    // Try the preferred account first.
    if let preferred = items.first(where: { $0.account == preferAccount }) {
        let (tok, _) = parseOAuthBlob(preferred.blob)
        if tok != nil { return preferred.blob }
    }
    // Fall through remaining items in order.
    for item in items where item.account != preferAccount {
        let (tok, _) = parseOAuthBlob(item.blob)
        if tok != nil { return item.blob }
    }
    return nil
}

/// Resolve a live OAuth token from injected sources — fully testable offline.
///
/// Priority: env → credentials file → keychain.
/// Re-call this on every fetch so token rotations by Claude Code are picked up
/// automatically (same discipline as clud's resolve_token).
public func resolveToken(
    env: [String: String],
    credentialsFileText: String?,
    keychainItems: [(account: String, blob: String)],
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

    // 3. Keychain: enumerate all items, prefer current username.
    if token == nil {
        if let blob = selectKeychainBlob(keychainItems, preferAccount: preferAccount) {
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

/// Read all generic-password items for the Claude Code credentials service via
/// Security framework (NOT `security` CLI — GUI apps don't inherit shell PATH and
/// SecItemCopyMatching avoids the extra process + parsing).
///
/// First call may trigger a one-time macOS Keychain authorization prompt.
/// Any failure (denial, missing item, OS error) returns an empty array → caller
/// falls through to "no_token" degraded state.
func readKeychainItems(service: String = keychainService) -> [(account: String, blob: String)] {
    let query: [CFString: Any] = [
        kSecClass:            kSecClassGenericPassword,
        kSecAttrService:      service,
        kSecMatchLimit:       kSecMatchLimitAll,
        kSecReturnAttributes: true,
        kSecReturnData:       true,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let items = result as? [[CFString: Any]]
    else { return [] }

    return items.compactMap { item -> (String, String)? in
        guard let data = item[kSecValueData] as? Data,
              let blob = String(data: data, encoding: .utf8)
        else { return nil }
        let account = (item[kSecAttrAccount] as? String) ?? "unknown"
        return (account, blob)
    }
}

/// Live token resolution using the real environment, credentials file, and Keychain.
///
/// Injecting NSUserName() as preferAccount picks the correct keychain item on machines
/// where multiple items share the "Claude Code-credentials" service (verified on dev machine).
public func resolveTokenLive() -> TokenResult {
    let env = ProcessInfo.processInfo.environment
    let fileText = try? String(contentsOf: credentialsPath, encoding: .utf8)
    let items = readKeychainItems()
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    return resolveToken(
        env: env,
        credentialsFileText: fileText,
        keychainItems: items,
        preferAccount: NSUserName(),
        nowMs: nowMs
    )
}
