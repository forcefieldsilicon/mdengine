import Foundation
import LAMMPSCore

/// Everything the run tracker does that is not a view (GJOB-121/122).
///
/// Deliberately split from the SwiftUI layer: deep-link parsing, credential storage and the grouping and
/// formatting of the job list are the parts that can be wrong in ways a Simulator screenshot would not
/// show, so they live here where `swift test` can reach them.

// MARK: - key entry

public enum KeyEntry {
    /// An MDEngine API key is `mde_` + 32 lowercase hex. Anything else is not a key, and the app should say
    /// so rather than sending it to `/v1/me` and reporting a 401 as if the server were at fault.
    public static func isWellFormed(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 36, t.hasPrefix("mde_") else { return false }
        return t.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Pull a key out of what a person actually pastes: the bare key, or the `mdengine login mde_…` line
    /// the /welcome page shows, or a `mdengine://key/mde_…` deep link.
    public static func extract(from pasted: String) -> String? {
        let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if isWellFormed(t) { return t }
        if let u = URL(string: t), let k = fromDeepLink(u) { return k }
        // last resort: the first token that looks like a key, so "mdengine login mde_…" works
        for token in t.split(whereSeparator: { " \t\n\"'`".contains($0) }) where isWellFormed(String(token)) {
            return String(token)
        }
        return nil
    }

    /// `mdengine://key/<mde_…>` — the scheme /welcome links to with "Open in MDEngine Runs".
    /// Also accepts `mdengine://key?k=<mde_…>` so the page can percent-encode if it ever needs to.
    public static func fromDeepLink(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "mdengine", (url.host ?? "").lowercased() == "key" else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if isWellFormed(path) { return path }
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "k" })?.value, isWellFormed(q) { return q }
        return nil
    }
}

// MARK: - credential storage

/// Where the tracker keeps its key. The key is a bearer token that spends real money, so on iOS it goes to
/// the Keychain rather than a file in the sandbox: Application Support would ride along in an unencrypted
/// backup, and the Keychain item here is `.whenUnlockedThisDeviceOnly`, so it never leaves the device.
/// macOS keeps using `~/.mdengine/credentials`, which the CLI and MCP server already share.
public protocol CredentialStore {
    func load() -> String?
    func save(_ key: String) throws
    func clear()
}

public struct FileCredentialStore: CredentialStore {
    public init() {}
    public func load() -> String? { HostedCredentials.load()?.apiKey }
    public func save(_ key: String) throws {
        let dir = HostedCredentials.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = try JSONEncoder().encode(HostedCredentials(apiKey: key))
        try json.write(to: HostedCredentials.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: HostedCredentials.fileURL.path)
    }
    public func clear() { try? FileManager.default.removeItem(at: HostedCredentials.fileURL) }
}

/// Picks the best available store and reports whether it had to settle for less.
///
/// This exists because the choice is a security posture, not a detail: the Keychain needs an
/// application-identifier entitlement, which a hand-assembled simulator bundle cannot have (an ad-hoc
/// signature cannot back one, and attaching it stops the app launching at all). Rather than silently
/// writing a money-bearing bearer token to a file and calling it the Keychain, this returns the file store
/// with `downgraded: true`, and the UI says so. On a properly signed build the Keychain is used and nothing
/// is shown.
public enum CredentialStoreFactory {
    public static func best() -> (store: CredentialStore, downgraded: Bool) {
        #if os(iOS)
        let kc = KeychainCredentialStore()
        if kc.isUsable { return (kc, false) }
        return (FileCredentialStore(), true)
        #else
        return (FileCredentialStore(), false)
        #endif
    }
}

/// In-memory, for tests and previews.
public final class MemoryCredentialStore: CredentialStore {
    private var key: String?
    public init(_ key: String? = nil) { self.key = key }
    public func load() -> String? { key }
    public func save(_ k: String) throws { key = k }
    public func clear() { key = nil }
}

// MARK: - the job list

/// One row, already formatted. The view renders these; it does no arithmetic and no date maths.
public struct JobRow: Identifiable, Equatable {
    public let id: String
    public let state: String
    public let gpu: String
    public let cost: String
    public let elapsed: String
    public let detail: String?
    /// A stable name for the state's colour, so the view's palette is the only place colours live.
    public let tint: Tint

    public enum Tint: String, Equatable { case running, queued, done, failed, cancelled }
}

public enum JobList {
    /// Newest first. The endpoint already returns newest-first, but a list that silently depends on server
    /// ordering breaks quietly the day it changes, so sort on `created` here too.
    public static func sorted(_ jobs: [HostedJobStatus]) -> [HostedJobStatus] {
        jobs.sorted { (a, b) in (a.created ?? "") > (b.created ?? "") }
    }

    /// Group by calendar day of `created`, in the order the groups should appear (newest day first).
    /// Returns section titles alongside their rows: "Today", "Yesterday", then an absolute date.
    public static func grouped(_ jobs: [HostedJobStatus], now: Date = Date(),
                               calendar: Calendar = .current) -> [(title: String, jobs: [HostedJobStatus])] {
        var buckets: [Date: [HostedJobStatus]] = [:]
        var undated: [HostedJobStatus] = []
        for j in sorted(jobs) {
            guard let d = parseTimestamp(j.created) else { undated.append(j); continue }
            buckets[calendar.startOfDay(for: d), default: []].append(j)
        }
        var out = buckets.keys.sorted(by: >).map { day in
            (title: dayTitle(day, now: now, calendar: calendar), jobs: buckets[day] ?? [])
        }
        if !undated.isEmpty { out.append((title: "Undated", jobs: undated)) }
        return out
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        // Compare against the passed-in `now`, not Calendar.isDateInToday: that reads the system clock, so
        // a test asserting "Today" would pass on the day it was written and fail the next morning.
        let today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(day, equalTo: now, toGranularity: .year)
                                             ? "MMMd" : "MMMdyyyy")
        return f.string(from: day)
    }

    /// The endpoint's timestamps are `2026-09-08T19:47:49Z`.
    public static func parseTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.date(from: s)
    }

    /// Should the list keep polling? Only while something can still change. A tracker that polls a screen
    /// of finished jobs forever is a battery bug, and one that stops while a job is launching is useless —
    /// GJOB-122 asks for a run to be "followed live".
    public static func shouldPoll(_ jobs: [HostedJobStatus]) -> Bool {
        jobs.contains { !$0.isTerminal }
    }

    /// How often to poll. The endpoint's own heartbeat is 30 s, so asking faster than that shows nothing
    /// new; while a job is launching there is no thermo to miss either, so one interval covers both.
    public static let pollInterval: Duration = .seconds(10)

    public static func row(_ j: HostedJobStatus, now: Date = Date()) -> JobRow {
        JobRow(id: j.id, state: j.state,
               gpu: j.gpu ?? "—",
               cost: costText(j),
               elapsed: elapsedText(j, now: now),
               detail: detailText(j),
               tint: tint(for: j.state))
    }

    static func tint(for state: String) -> JobRow.Tint {
        switch state {
        case "running", "uploading": return .running
        case "created", "uploaded", "queued", "launching": return .queued
        case "done": return .done
        case "cancelled": return .cancelled
        default: return .failed
        }
    }

    /// Cost is money, so it is never rounded up into a prettier number and never shown as "$0.00" for a job
    /// that has in fact been billed a fraction of a cent.
    static func costText(_ j: HostedJobStatus) -> String {
        guard let c = j.cost_usd, c > 0 else { return "$0" }
        return c < 0.01 ? String(format: "$%.4f", c) : String(format: "$%.2f", c)
    }

    static func elapsedText(_ j: HostedJobStatus, now: Date) -> String {
        if let b = j.billed_s, b > 0 { return duration(b) }
        // Nothing billed yet: show how long it has been waiting, which is the number you actually want
        // while a job sits in `launching` on a cold host.
        guard let start = parseTimestamp(j.started) ?? parseTimestamp(j.created) else { return "—" }
        return duration(max(0, Int(now.timeIntervalSince(start))))
    }

    static func duration(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// The one line under the row: whatever is most worth knowing right now.
    static func detailText(_ j: HostedJobStatus) -> String? {
        if let e = j.error { return errorExplanation(e) }
        if j.state == "running", let t = j.thermo_tail?.last, !t.isEmpty {
            return t.trimmingCharacters(in: .whitespaces)
        }
        if let a = j.attempt, a > 1 { return "relaunched (attempt \(a))" }
        return nil
    }

    /// Endpoint error codes in the customer's words. `launch_timeout` is the GJOB-141 one; all four of these
    /// are infrastructure faults the customer is never billed for, and the app says so, because "failed" with
    /// a charge of $0 and no explanation is how you lose someone's trust.
    public static func errorExplanation(_ code: String) -> String {
        switch code {
        case "pod_lost":        return "the GPU host dropped out — not billed"
        case "no_capacity":     return "no GPU was available — not billed"
        case "launch_timeout":  return "the GPU never came up — not billed"
        case "gpu_unavailable": return "the host gave the job no GPU — not billed"
        case "wall_limit":      return "hit its wall-clock cap"
        case "cancelled":       return "cancelled"
        case "no_results":      return "finished but produced no results file"
        case "lammps_error":    return "LAMMPS stopped with an error — see the log"
        case "runner_error":    return "the runner failed before LAMMPS started"
        default:                return code
        }
    }
}
