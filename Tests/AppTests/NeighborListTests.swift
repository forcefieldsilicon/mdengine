import XCTest
@testable import LAMMPSCore

/// Deterministic LCG — a flaky neighbour-list test is worse than no test.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class NeighborListTests: XCTestCase {
    private func randomPositions(_ n: Int, span: Double, seed: UInt64 = 42) -> [SIMD3<Double>] {
        var rng = SeededRNG(state: seed)
        return (0..<n).map { _ in
            SIMD3(Double.random(in: 0..<span, using: &rng),
                  Double.random(in: 0..<span, using: &rng),
                  Double.random(in: 0..<span, using: &rng))
        }
    }

    private func bruteForce(_ p: [SIMD3<Double>], cutoff: Double, box: SimulationBox?) -> [Set<Int>] {
        (0..<p.count).map { i in
            var s = Set<Int>()
            for j in 0..<p.count where j != i {
                var d = p[j] - p[i]
                if let box { d = box.minimumImage(d) }
                if (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() <= cutoff { s.insert(j) }
            }
            return s
        }
    }

    func testMatchesBruteForceWithPBC() {
        let p = randomPositions(500, span: 20)
        let box = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(20, 20, 20))
        let nl = NeighborList(positions: p, cutoff: 3.0, box: box)
        let expected = bruteForce(p, cutoff: 3.0, box: box)
        for i in p.indices {
            XCTAssertEqual(Set(nl.neighbors(of: i)), expected[i], "atom \(i)")
        }
    }

    func testMatchesBruteForceOpenBoundaries() {
        let p = randomPositions(500, span: 20, seed: 7)
        let nl = NeighborList(positions: p, cutoff: 3.0, box: nil)
        let expected = bruteForce(p, cutoff: 3.0, box: nil)
        for i in p.indices {
            XCTAssertEqual(Set(nl.neighbors(of: i)), expected[i], "atom \(i)")
        }
    }

    /// Two cells per axis is the case where a naive 27-cell sweep double-counts.
    func testSmallPeriodicBoxDoesNotDoubleCount() {
        let p = randomPositions(200, span: 7, seed: 3)
        let box = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(7, 7, 7))
        let nl = NeighborList(positions: p, cutoff: 3.0, box: box)
        let expected = bruteForce(p, cutoff: 3.0, box: box)
        for i in p.indices {
            XCTAssertEqual(nl.neighbors(of: i).count, expected[i].count, "atom \(i) counted twice?")
            XCTAssertEqual(Set(nl.neighbors(of: i)), expected[i])
        }
    }

    func testKNearestOnACubicLattice() {
        // 4×4×4 simple cubic, spacing 1: 6 nearest at 1.0, then 12 at √2.
        var p: [SIMD3<Double>] = []
        for x in 0..<4 { for y in 0..<4 { for z in 0..<4 {
            p.append(SIMD3(Double(x), Double(y), Double(z)))
        } } }
        let box = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(4, 4, 4))
        let nl = NeighborList(positions: p, cutoff: 1.8, box: box)
        let near = nl.kNearest(of: 0, k: 6)
        XCTAssertEqual(near.count, 6)
        for n in near { XCTAssertEqual(n.distance, 1.0, accuracy: 1e-9) }
        XCTAssertEqual(nl.kNearest(of: 0, k: 100).count, nl.neighbors(of: 0).count)
    }

    func testCancellationStopsTheBuild() {
        let p = randomPositions(60_000, span: 60, seed: 11)
        var calls = 0
        let nl = NeighborList(positions: p, cutoff: 3.0, box: nil, isCancelled: {
            calls += 1
            return true
        })
        XCTAssertTrue(nl.wasCancelled)
        XCTAssertGreaterThan(calls, 0)
        XCTAssertTrue(nl.neighbors(of: 0).isEmpty)   // a cancelled list answers nothing
    }
}
