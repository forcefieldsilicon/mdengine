import XCTest
@testable import LAMMPSCore

final class AnalysisSchedulerTests: XCTestCase {
    /// Direct publisher so the test does not depend on the main run loop.
    private func makeScheduler() -> AnalysisScheduler {
        AnalysisScheduler(publish: { $0() })
    }

    func testLatestWinsUnderBurst() {
        let s = makeScheduler()
        let published = NSLock()
        var values: [Int] = []
        let done = expectation(description: "last value published")
        for i in 0..<50 {
            s.submit(lane: "z", compute: { _ in
                usleep(5_000)      // 5 ms of "work" per request
                return i
            }, onResult: { v in
                published.lock(); values.append(v); published.unlock()
                if v == 49 { done.fulfill() }
            })
        }
        wait(for: [done], timeout: 5)
        usleep(50_000)   // let any stragglers finish (there must be none)
        published.lock(); let got = values; published.unlock()
        XCTAssertEqual(got.last, 49)
        XCTAssertLessThanOrEqual(got.count, 2, "at most the in-flight and the newest request may publish")
        let st = s.stats()["z"]!
        XCTAssertGreaterThanOrEqual(st.dropped, 47)
        XCTAssertEqual(st.runs + st.cancelled, got.count + st.cancelled)
    }

    func testRunningJobSeesCancellation() {
        let s = makeScheduler()
        let sawCancel = expectation(description: "first job observed cancellation")
        let second = expectation(description: "second result published")
        let started = DispatchSemaphore(value: 0)
        s.submit(lane: "a", compute: { isCancelled in
            started.signal()
            for _ in 0..<2_000 {          // ≤ 2 s; exits as soon as superseded
                if isCancelled() { sawCancel.fulfill(); return 1 }
                usleep(1_000)
            }
            return 1
        }, onResult: { _ in XCTFail("stale result must not publish") })
        started.wait()
        s.submit(lane: "a", compute: { _ in 2 }, onResult: { v in
            XCTAssertEqual(v, 2); second.fulfill()
        })
        wait(for: [sawCancel, second], timeout: 5)
    }

    func testLanesAreIndependent() {
        let s = makeScheduler()
        let a = expectation(description: "a"), b = expectation(description: "b")
        s.submit(lane: "a", compute: { _ in usleep(20_000); return "a" }, onResult: { _ in a.fulfill() })
        s.submit(lane: "b", compute: { _ in "b" }, onResult: { _ in b.fulfill() })
        wait(for: [a, b], timeout: 5)
        XCTAssertEqual(s.stats()["a"]?.runs, 1)
        XCTAssertEqual(s.stats()["b"]?.runs, 1)
    }
}
