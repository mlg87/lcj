/// CookieStore.swift — UserDefaults-backed persistence for the pasted session cookie.
///
/// WHY UserDefaults (not Keychain): Keychain ACL binds to the ad-hoc code signature,
/// so every rebuild re-prompts "Always Allow" — the exact problem being removed.
/// UserDefaults (com.mlg87.clusage-menubar domain) survives rebuilds and reinstalls
/// because the domain is per-user, not per-signature. Approach matches ClaudeUsageBar
/// (Artzainnn/ClaudeUsageBar, 249★, shipping). The value is stored unencrypted in the
/// app's preferences plist — same trust level as the browser profile it was copied from;
/// it is never logged and never sent anywhere but claude.ai.

import ClusageCore
import Foundation

/// Pasted-cookie persistence via UserDefaults.
enum CookieStore {
    static let defaultsKey = "session_cookie"

    /// Resolution order: CLUSAGE_COOKIE env var → stored UserDefaults value.
    /// Returns nil when neither source yields a non-empty sanitized string.
    /// Re-called on every fetch so manual updates take effect without restart.
    ///
    /// WHY CLUSAGE_COOKIE env override: allows tests and CI to inject a cookie
    /// without touching the live UserDefaults domain on the dev machine.
    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLUSAGE_COOKIE"] {
            let s = sanitizeCookie(env)
            if !s.isEmpty { return s }
        }
        if let stored = UserDefaults.standard.string(forKey: defaultsKey) {
            let s = sanitizeCookie(stored)
            if !s.isEmpty { return s }
        }
        return nil
    }

    /// Sanitizes `raw` before storing — never persists the "Cookie:" label if the
    /// user copies the full header line instead of just the value.
    static func save(_ raw: String) {
        UserDefaults.standard.set(sanitizeCookie(raw), forKey: defaultsKey)
    }
}
