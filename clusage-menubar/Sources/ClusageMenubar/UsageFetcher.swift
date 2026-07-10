/// UsageFetcher.swift — URLSession-based fetcher for the Anthropic OAuth usage endpoint.
///
/// Ports the fetch discipline from clud/plugin/usage_fetcher.py:
/// - Same headers (Authorization, anthropic-beta, User-Agent)
/// - Same UA detection logic (explicit binary paths; GUI apps don't inherit shell PATH)
/// - Same failure-reason vocabulary: no_token / expired / network / http_401 / http_5xx / bad_shape
/// - Re-resolves the token on every fetch so Claude Code token rotations are transparent.

import AppKit
import ClusageCore
import Foundation

// MARK: - State machine

/// The outcome of a fetch cycle.
enum FetchState {
    case ok(UsageSnapshot, updatedAt: Date)
    case degraded(reason: String, updatedAt: Date)
}

// MARK: - UA detection

/// Claude binary search paths in probe order.
/// WHY explicit paths: GUI apps launched from the Dock / Finder don't inherit
/// the user's shell PATH, so `claude` on PATH is invisible here.
private let claudeBinaryPaths = [
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path,
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
]

private let fallbackUserAgent = "claude-code/2.1.198"   // verified live 2026-07-10

/// Detect the claude-code/<version> User-Agent string required by the endpoint.
///
/// WHY required: without `claude-code/<version>` the request is routed to a
/// throttled bucket that returns persistent 429s (see clud's usage_fetcher.py docstring).
/// We probe explicit paths rather than relying on $PATH because GUI apps don't
/// inherit the shell environment. Falls back to a known-good constant.
func detectUserAgent() -> String {
    for path in claudeBinaryPaths {
        guard FileManager.default.isExecutableFile(atPath: path) else { continue }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // suppress stderr
        do {
            try proc.run()
            // 5-second timeout so a hung binary doesn't stall launch.
            let deadline = Date(timeIntervalSinceNow: 5)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning { proc.terminate() }
        } catch {
            continue
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8),
           let first = output.split(separator: " ").first,
           !first.isEmpty {
            return "claude-code/\(first)"
        }
    }
    return fallbackUserAgent
}

// MARK: - Fetcher

final class UsageFetcher: @unchecked Sendable {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    private let userAgent: String
    private let session: URLSession
    /// Called on the main thread with each new FetchState.
    var onUpdate: ((FetchState) -> Void)?

    init() {
        userAgent = detectUserAgent()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
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
        let ua = userAgent
        let s = session
        Task {
            let state = await Self.fetch(session: s, userAgent: ua)
            // Back on the main actor after await — onUpdate access is safe.
            self.onUpdate?(state)
        }
    }

    private static func fetch(session: URLSession, userAgent: String) async -> FetchState {
        let now = Date()

        // Re-resolve token on every fetch — picks up Claude Code token rotations.
        let tr = resolveTokenLive()
        guard let token = tr.token else {
            return .degraded(reason: tr.reason ?? "no_token", updatedAt: now)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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
}
