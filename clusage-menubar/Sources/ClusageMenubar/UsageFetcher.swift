/// UsageFetcher.swift — URLSession-based fetcher for the claude.ai org-usage endpoint.
///
/// Auth: pasted session cookie stored via CookieStore (UserDefaults). Ported from
/// Artzainnn/ClaudeUsageBar (249★, shipping). Headers copied verbatim — claude.ai
/// fronts with bot protection; a browser UA + Origin/Referer passes it.
///
/// Failure vocabulary: no_cookie / no_org_id / network / http_401 / http_5xx / bad_shape

import ClusageCore
import Foundation

// MARK: - State machine

/// The outcome of a fetch cycle.
enum FetchState {
    case ok(UsageSnapshot, updatedAt: Date)
    case degraded(reason: String, updatedAt: Date)
}

// MARK: - Fetcher

private let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

final class UsageFetcher: @unchecked Sendable {
    private let session: URLSession
    /// Called on the main thread with each new FetchState.
    var onUpdate: ((FetchState) -> Void)?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        // WHY disable cookie storage: we send the pasted Cookie header verbatim.
        // Default URLSession cookie storage would capture Set-Cookie responses and
        // merge/override our header on later requests, making behavior drift from
        // the pasted value. Disable both directions.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    /// Fire-and-forget fetch; calls onUpdate on the main actor when done.
    ///
    /// WHY @MainActor + plain Task (not Task.detached): Swift 6 strict concurrency forbids
    /// sending a non-Sendable closure (onUpdate) across task boundaries. A Task created from
    /// a @MainActor context inherits that context; after the awaited nonisolated fetch returns,
    /// control resumes on the main actor so onUpdate is safe to invoke directly.
    @MainActor
    func fetchNow() {
        let s = session
        Task {
            let state = await Self.fetch(session: s)
            // Back on the main actor after await — onUpdate access is safe.
            self.onUpdate?(state)
        }
    }

    /// Build a request with the browser headers claude.ai requires.
    ///
    /// WHY these headers: claude.ai uses bot protection; a Chrome browser UA plus
    /// Origin/Referer/authority are required to get a 200 (verified by ClaudeUsageBar).
    /// Copied verbatim from the reference implementation.
    private static func claudeRequest(url: URL, cookie: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        r.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        r.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("claude.ai", forHTTPHeaderField: "authority")
        return r
    }

    private static func fetch(session: URLSession) async -> FetchState {
        let now = Date()

        guard let cookie = CookieStore.load() else {
            return .degraded(reason: "no_cookie", updatedAt: now)
        }

        // Try to extract orgId from the cookie (free operation for devtools copies that
        // include lastActiveOrg=). Fall back to /api/bootstrap for cookies that omit it.
        var org = orgId(fromCookie: cookie)
        if org == nil {
            org = await Self.bootstrapOrgId(session: session, cookie: cookie)
        }
        guard let orgId = org else {
            return .degraded(reason: "no_org_id", updatedAt: now)
        }

        let usageURL = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: claudeRequest(url: usageURL, cookie: cookie))
        } catch {
            return .degraded(reason: "network", updatedAt: now)
        }

        guard let http = response as? HTTPURLResponse else {
            return .degraded(reason: "network", updatedAt: now)
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            return .degraded(reason: "http_401", updatedAt: now)
        default:
            return .degraded(reason: "http_5xx", updatedAt: now)
        }

        guard let snapshot = UsageSnapshot.parse(data) else {
            return .degraded(reason: "bad_shape", updatedAt: now)
        }

        return .ok(snapshot, updatedAt: now)
    }

    /// GET /api/bootstrap → account.lastActiveOrgId. Returns nil on any failure.
    ///
    /// WHY this fallback: some cookie strings (e.g. partial pastes missing lastActiveOrg)
    /// don't carry the org UUID directly. ClaudeUsageBar uses this same fallback.
    private static func bootstrapOrgId(session: URLSession, cookie: String) async -> String? {
        let url = URL(string: "https://claude.ai/api/bootstrap")!
        guard let (data, resp) = try? await session.data(for: claudeRequest(url: url, cookie: cookie)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any],
              let id = account["lastActiveOrgId"] as? String, !id.isEmpty
        else { return nil }
        return id
    }
}
