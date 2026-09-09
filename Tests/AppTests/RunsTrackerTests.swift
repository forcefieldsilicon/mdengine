import XCTest
@testable import MDEngineRunsUI
@testable import LAMMPSCore

/// The tracker's non-view logic (GJOB-121/122). Everything here is a thing a Simulator screenshot would not
/// catch: a key that is accepted but malformed, a cost rounded to $0.00, a day boundary, an error code shown
/// as a raw string to a paying customer.
final class RunsTrackerTests: XCTestCase {

    // MARK: key entry

    func testWellFormedKeys() {
        let good = "mde_" + String(repeating: "a1b2c3d4", count: 4)   // 4 + 32
        XCTAssertTrue(KeyEntry.isWellFormed(good))
        XCTAssertTrue(KeyEntry.isWellFormed("  \(good)\n"))           // pasted with whitespace
        XCTAssertFalse(KeyEntry.isWellFormed(""))
        XCTAssertFalse(KeyEntry.isWellFormed("mde_short"))
        XCTAssertFalse(KeyEntry.isWellFormed(good + "a"))             // too long
        XCTAssertFalse(KeyEntry.isWellFormed("key_" + String(repeating: "a", count: 32)))
        XCTAssertFalse(KeyEntry.isWellFormed("mde_" + String(repeating: "A", count: 32)))  // uppercase is not ours
        XCTAssertFalse(KeyEntry.isWellFormed("mde_" + String(repeating: "z", count: 32)))  // not hex
    }

    func testExtractFromWhatPeopleActuallyPaste() {
        let key = "mde_" + String(repeating: "0f", count: 16)
        XCTAssertEqual(KeyEntry.extract(from: key), key)
        // The line the /welcome page prints.
        XCTAssertEqual(KeyEntry.extract(from: "mdengine login \(key)"), key)
        XCTAssertEqual(KeyEntry.extract(from: "  mdengine login \(key)  \n"), key)
        // Quoted, as it arrives out of a shell snippet or a chat client.
        XCTAssertEqual(KeyEntry.extract(from: "\"\(key)\""), key)
        XCTAssertEqual(KeyEntry.extract(from: "mdengine://key/\(key)"), key)
        XCTAssertNil(KeyEntry.extract(from: "no key in this sentence"))
        XCTAssertNil(KeyEntry.extract(from: "mde_notavalidkey"))
    }

    func testDeepLink() {
        let key = "mde_" + String(repeating: "ab", count: 16)
        XCTAssertEqual(KeyEntry.fromDeepLink(URL(string: "mdengine://key/\(key)")!), key)
        XCTAssertEqual(KeyEntry.fromDeepLink(URL(string: "MDENGINE://KEY/\(key)")!), key)   // scheme is case-insensitive
        XCTAssertEqual(KeyEntry.fromDeepLink(URL(string: "mdengine://key?k=\(key)")!), key)
        // Anything that is not our scheme+host, or carries a bad key, is ignored rather than half-accepted.
        XCTAssertNil(KeyEntry.fromDeepLink(URL(string: "https://example.com/key/\(key)")!))
        XCTAssertNil(KeyEntry.fromDeepLink(URL(string: "mdengine://job/\(key)")!))
        XCTAssertNil(KeyEntry.fromDeepLink(URL(string: "mdengine://key/mde_bogus")!))
    }

    // MARK: credential store

    func testMemoryStoreRoundTrip() throws {
        let s = MemoryCredentialStore()
        XCTAssertNil(s.load())
        try s.save("mde_" + String(repeating: "1", count: 32))
        XCTAssertEqual(s.load(), "mde_" + String(repeating: "1", count: 32))
        s.clear()
        XCTAssertNil(s.load())
    }

    @MainActor
    func testStoreDowngradeIsCarriedIntoTheModelNotSwallowed() {
        // The point of the flag is that the UI can say where the key went. If it silently defaulted to
        // false, a file-stored bearer token would be presented as Keychain-stored.
        let m = RunsViewModel(store: MemoryCredentialStore(), storeIsDowngraded: true)
        XCTAssertTrue(m.storeIsDowngraded)
        XCTAssertFalse(RunsViewModel(store: MemoryCredentialStore()).storeIsDowngraded)
    }

    func testFactoryOnMacUsesTheFileStoreAndCallsItNoDowngrade() {
        // macOS has no Keychain requirement here: ~/.mdengine/credentials is the shared, intended location,
        // so it must not be reported as a downgrade.
        let picked = CredentialStoreFactory.best()
        XCTAssertFalse(picked.downgraded)
        XCTAssertTrue(picked.store is FileCredentialStore)
    }

    // MARK: rows

    private func job(_ id: String, state: String, created: String? = "2026-09-08T12:00:00Z",
                     started: String? = nil, gpu: String? = "rtx4090", billed: Int? = nil,
                     cost: Double? = nil, error: String? = nil, attempt: Int? = 1,
                     thermo: [String]? = nil) -> HostedJobStatus {
        let json: [String: Any?] = ["id": id, "state": state, "created": created, "started": started,
                                    "finished": nil, "gpu": gpu, "rate_usd_per_h": 2.0, "billed_s": billed,
                                    "cost_usd": cost, "thermo_tail": thermo, "exitcode": nil,
                                    "error": error, "attempt": attempt]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(HostedJobStatus.self, from: data)
    }

    func testSubCentCostIsNotRoundedToZero() {
        // A 3-second job bills $0.0017. Showing "$0.00" would tell the customer it was free.
        let r = JobList.row(job("J1", state: "done", billed: 3, cost: 0.0017))
        XCTAssertEqual(r.cost, "$0.0017")
        XCTAssertEqual(JobList.row(job("J2", state: "done", billed: 900, cost: 0.5)).cost, "$0.50")
        XCTAssertEqual(JobList.row(job("J3", state: "queued")).cost, "$0")
    }

    func testElapsedUsesBilledWhenBilledOtherwiseWaiting() {
        XCTAssertEqual(JobList.row(job("J", state: "done", billed: 138, cost: 0.07)).elapsed, "2m 18s")
        XCTAssertEqual(JobList.row(job("J", state: "done", billed: 3700, cost: 2.0)).elapsed, "1h 1m")
        // Launching with nothing billed: show the wait, which is the number that matters on a cold host.
        let created = "2026-09-08T12:00:00Z"
        let now = JobList.parseTimestamp(created)!.addingTimeInterval(90)
        XCTAssertEqual(JobList.row(job("J", state: "launching", created: created), now: now).elapsed, "1m 30s")
    }

    func testTintCoversEveryEndpointState() {
        // Every state in CONTRACT.md's `states` list must map to a colour; an unmapped one must not read
        // as success.
        let states = "created uploaded queued launching running uploading done failed cancelled".split(separator: " ").map(String.init)
        for s in states {
            let t = JobList.row(job("J", state: s)).tint
            if s == "done" { XCTAssertEqual(t, .done) }
            else if s == "cancelled" { XCTAssertEqual(t, .cancelled) }
            else if s == "failed" { XCTAssertEqual(t, .failed) }
            else { XCTAssertNotEqual(t, .done, "\(s) must not look finished") }
        }
        XCTAssertEqual(JobList.row(job("J", state: "some_new_state")).tint, .failed)
    }

    func testInfrastructureErrorsSayNotBilled() {
        // These four are the endpoint's NOT_BILLED_ERRORS. A customer seeing "failed" with no explanation
        // is the trust problem this text exists to prevent.
        for code in ["pod_lost", "no_capacity", "launch_timeout", "gpu_unavailable"] {
            XCTAssertTrue(JobList.errorExplanation(code).contains("not billed"), code)
        }
        XCTAssertEqual(JobList.errorExplanation("wall_limit"), "hit its wall-clock cap")
        XCTAssertEqual(JobList.errorExplanation("something_new"), "something_new")   // never invents meaning
    }

    func testDetailPrefersErrorThenThermoThenRelaunch() {
        XCTAssertEqual(JobList.row(job("J", state: "failed", error: "launch_timeout")).detail,
                       "the GPU never came up — not billed")
        XCTAssertEqual(JobList.row(job("J", state: "running", thermo: ["step 1", "  step 2  "])).detail, "step 2")
        XCTAssertEqual(JobList.row(job("J", state: "launching", attempt: 2)).detail, "relaunched (attempt 2)")
        XCTAssertNil(JobList.row(job("J", state: "queued")).detail)
    }

    func testPollsOnlyWhileSomethingCanStillChange() {
        // Stops on a screen of finished work (battery), keeps going while anything is in flight (the whole
        // point of a tracker).
        XCTAssertFalse(JobList.shouldPoll([]))
        XCTAssertFalse(JobList.shouldPoll([job("a", state: "done"), job("b", state: "failed"),
                                           job("c", state: "cancelled")]))
        for live in ["created", "uploaded", "queued", "launching", "running", "uploading"] {
            XCTAssertTrue(JobList.shouldPoll([job("a", state: "done"), job("b", state: live)]), live)
        }
    }

    // MARK: grouping

    func testSortedIsNewestFirstRegardlessOfServerOrder() {
        let a = job("A", state: "done", created: "2026-09-06T10:00:00Z")
        let b = job("B", state: "done", created: "2026-09-08T10:00:00Z")
        let c = job("C", state: "done", created: "2026-09-07T10:00:00Z")
        XCTAssertEqual(JobList.sorted([a, b, c]).map(\.id), ["B", "C", "A"])
    }

    func testGroupedByDayNewestDayFirstWithTodayAndYesterday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // A fixed `now` in the past: this must keep passing next year, not just on 2026-09-08.
        let now = JobList.parseTimestamp("2026-09-08T20:00:00Z")!
        let jobs = [job("today1", state: "done", created: "2026-09-08T19:00:00Z"),
                    job("today2", state: "done", created: "2026-09-08T09:00:00Z"),
                    job("yday", state: "done", created: "2026-09-07T09:00:00Z"),
                    job("older", state: "done", created: "2026-09-01T09:00:00Z")]
        let g = JobList.grouped(jobs, now: now, calendar: cal)
        XCTAssertEqual(Array(g.map { $0.title }.prefix(2)), ["Today", "Yesterday"])
        XCTAssertEqual(g[0].jobs.map(\.id), ["today1", "today2"])       // newest first inside the day
        XCTAssertEqual(g[1].jobs.map(\.id), ["yday"])
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g[2].jobs.map(\.id), ["older"])
        XCTAssertFalse(g[2].title.isEmpty)
        XCTAssertNotEqual(g[2].title, "Today")
    }

    func testJobsWithNoTimestampAreKeptNotDropped() {
        // A job the endpoint returned without `created` must still be visible; silently dropping runs a
        // customer paid for is worse than an ugly section.
        let jobs = [job("dated", state: "done", created: "2026-09-08T10:00:00Z"),
                    job("undated", state: "created", created: nil)]
        let g = JobList.grouped(jobs)
        XCTAssertEqual(g.flatMap { $0.jobs }.count, 2)
        XCTAssertEqual(g.last?.title, "Undated")
    }

    func testParseTimestampRejectsGarbage() {
        XCTAssertNotNil(JobList.parseTimestamp("2026-09-08T19:47:49Z"))
        XCTAssertNil(JobList.parseTimestamp(nil))
        XCTAssertNil(JobList.parseTimestamp(""))
        XCTAssertNil(JobList.parseTimestamp("2026-09-08 19:47:49"))
        XCTAssertNil(JobList.parseTimestamp("not a date"))
    }
}
