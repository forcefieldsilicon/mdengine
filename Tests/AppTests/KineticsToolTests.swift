import XCTest
@testable import LAMMPSCore

/// Synthetic τRAMD side files only — the real study's data stays in the study repo.
final class KineticsToolTests: XCTestCase {

    // MARK: - synthetic side files

    /// `tramd_times.csv` as `tramd.py` writes it (censored = 1/0, CRLF from python's csv).
    private func timesCSV(_ rows: [(seed: Int, replica: Int, t: Double, censored: Bool)],
                          newline: String = "\n") -> String {
        var out = "seed,replica,t_diss_ps,censored,final_com_distance_nm,n_redirect,wall_s,trajectory" + newline
        for r in rows {
            out += "\(r.seed),\(r.replica),\(String(format: "%.14g", r.t)),\(r.censored ? 1 : 0),"
                + "\(r.censored ? "1.2" : "3.4"),7,12.5," + newline
        }
        return out
    }

    private func rows(seed: Int, times: [Double], censored: [Bool]? = nil)
        -> [(seed: Int, replica: Int, t: Double, censored: Bool)] {
        times.enumerated().map { (seed: seed, replica: $0.offset, t: $0.element,
                                  censored: censored?[$0.offset] ?? false) }
    }

    private func tempDir(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("tramd-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func frame() -> Frame { Frame(atoms: [Arv(element: "C", x: 0, y: 0, z: 0)]) }

    private func value(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.value
    }

    // MARK: - τ interpolation

    func testTauIsTheInterpolatedFiftyPercentPoint() {
        // even n: the 50 % point lands exactly on a replica time
        XCTAssertEqual(RAMDResults.tau(times: [100, 200, 300, 400], censored: [false, false, false, false],
                                       maxTime_ps: 400)!, 200, accuracy: 1e-12)
        // odd n: CDF steps 1/3, 2/3 — 50 % sits halfway between the first two times
        XCTAssertEqual(RAMDResults.tau(times: [100, 200, 300], censored: [false, false, false],
                                       maxTime_ps: 300)!, 150, accuracy: 1e-12)
        // order in the file must not matter
        XCTAssertEqual(RAMDResults.tau(times: [400, 100, 300, 200], censored: [Bool](repeating: false, count: 4),
                                       maxTime_ps: 400)!, 200, accuracy: 1e-12)
        // n = 2: the CDF reaches 50 % exactly at the first time
        XCTAssertEqual(RAMDResults.tau(times: [100, 200], censored: [false, false],
                                       maxTime_ps: 200)!, 100, accuracy: 1e-12)
        // the CDF is anchored at (0, 0), so one replica reads as half its time — a
        // reminder that τ from a single replica is not a measurement
        XCTAssertEqual(RAMDResults.tau(times: [42], censored: [false], maxTime_ps: 42)!, 21, accuracy: 1e-12)
    }

    func testCensoredReplicasEnterAtTMaxAndGateTau() throws {
        // half censored: they sort to the end, τ is still bracketed
        let half = RAMDResults(replicas: [
            .init(seed: 1, replica: 0, time_ps: 100, censored: false),
            .init(seed: 1, replica: 1, time_ps: 200, censored: false),
            .init(seed: 1, replica: 2, time_ps: 1000, censored: true),
            .init(seed: 1, replica: 3, time_ps: 1000, censored: true)])
        XCTAssertEqual(half.maxTime_ps, 1000)
        XCTAssertEqual(half.censoredFraction, 0.5, accuracy: 1e-12)
        XCTAssertEqual(half.tau!, 200, accuracy: 1e-12)
        XCTAssertEqual(half.seeds.first?.dissociated, 2)

        // majority censored: no number — the median is not bracketed
        let mostly = RAMDResults(replicas: [
            .init(seed: 1, replica: 0, time_ps: 100, censored: false),
            .init(seed: 1, replica: 1, time_ps: 1000, censored: true),
            .init(seed: 1, replica: 2, time_ps: 1000, censored: true)])
        XCTAssertNil(mostly.tau)
        XCTAssertEqual(mostly.censoredFraction, 2.0 / 3.0, accuracy: 1e-12)

        // and the survival curve counts censored replicas as bound for ever
        XCTAssertEqual(half.fractionBound(at: 150), 0.75, accuracy: 1e-12)
        XCTAssertEqual(half.fractionBound(at: 999_999), 0.5, accuracy: 1e-12)
    }

    func testTauPerSeedAndOverallMean() {
        let text = timesCSV(rows(seed: 11, times: [100, 200, 300, 400])
                            + rows(seed: 22, times: [300, 400, 500, 600]))
        let r = RAMDResults(replicas: RAMDResults.parseTimes(text))
        XCTAssertEqual(r.seeds.map { $0.seed }, [11, 22])
        XCTAssertEqual(r.tauPerSeed.map { $0.tau! }, [200, 400])
        XCTAssertEqual(r.tau!, 300, accuracy: 1e-12)          // mean over seeds, not over replicas
    }

    // MARK: - bootstrap

    func testBootstrapCIBracketsTauAndIsReproducible() throws {
        let times: [Double] = [80, 120, 150, 190, 240, 300, 380, 500]
        let r = RAMDResults(replicas: RAMDResults.parseTimes(timesCSV(rows(seed: 7, times: times))))
        let tau = try XCTUnwrap(r.tau)
        let ci = try XCTUnwrap(r.bootstrapCI(samples: 500))
        XCTAssertLessThan(ci.lo, ci.hi)
        XCTAssertLessThanOrEqual(ci.lo, tau)
        XCTAssertGreaterThanOrEqual(ci.hi, tau)
        XCTAssertGreaterThanOrEqual(ci.lo, times.min()!)
        XCTAssertLessThanOrEqual(ci.hi, times.max()!)

        let again = try XCTUnwrap(r.bootstrapCI(samples: 500))
        XCTAssertEqual(ci.lo, again.lo)                       // seeded RNG: identical twice
        XCTAssertEqual(ci.hi, again.hi)
        // a different seed is still a valid interval on the same data
        let other = try XCTUnwrap(r.bootstrapCI(samples: 500, rngSeed: 999))
        XCTAssertLessThanOrEqual(other.lo, tau)
        XCTAssertGreaterThanOrEqual(other.hi, tau)

        // every replica identical → a zero-width interval exactly at τ
        let flat = RAMDResults(replicas: RAMDResults.parseTimes(
            timesCSV(rows(seed: 1, times: [250, 250, 250, 250]))))
        let fci = try XCTUnwrap(flat.bootstrapCI(samples: 200))
        XCTAssertEqual(fci.lo, 250, accuracy: 1e-12)
        XCTAssertEqual(fci.hi, 250, accuracy: 1e-12)
    }

    // MARK: - parsing

    func testCRLFParsesLikeLF() {
        let lf = timesCSV(rows(seed: 3, times: [100, 200, 300], censored: [false, false, true]))
        let crlf = timesCSV(rows(seed: 3, times: [100, 200, 300], censored: [false, false, true]),
                            newline: "\r\n")
        let a = RAMDResults.parseTimes(lf), b = RAMDResults.parseTimes(crlf)
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(b.count, 3, "CRLF (python csv default) must parse like LF")
        XCTAssertEqual(a.map { $0.time_ps }, b.map { $0.time_ps })
        XCTAssertEqual(b.map { $0.censored }, [false, false, true])

        // survival file, and tolerance for junk
        let surv = "t_ps,seed,fraction_bound\r\n0,3,1.0\r\n50,3,0.667\r\nnan,3,0.5\r\n100,3,0.333\r\n"
        let pts = RAMDResults.parseSurvival(surv)
        XCTAssertEqual(pts.count, 3)                          // the NaN row is dropped
        XCTAssertEqual(pts.last?.fractionBound, 0.333)
        XCTAssertTrue(RAMDResults.parseTimes("1,2,3\n4,5,6\n").isEmpty)   // headerless: not our file
    }

    // MARK: - locating side files

    func testLocateFindsCSVBesideTrajectoryAndInResultsSibling() throws {
        let dir = try tempDir("locate")
        let traj = dir.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        XCTAssertNil(RAMDResults.locate(near: traj))

        let beside = dir.appendingPathComponent("tramd_times.csv")
        try timesCSV(rows(seed: 5, times: [100, 200, 300, 400])).write(to: beside, atomically: true, encoding: .utf8)
        XCTAssertEqual(RAMDResults.locate(near: traj)?.path, beside.path)

        // run layout: trajectory and CSV in results/, found from the run directory too
        let run = try tempDir("run")
        let results = run.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let inResults = results.appendingPathComponent("tramd_times.csv")
        try timesCSV(rows(seed: 5, times: [100, 200])).write(to: inResults, atomically: true, encoding: .utf8)
        func real(_ u: URL?) -> String? { u?.resolvingSymlinksInPath().path }   // /var → /private/var
        XCTAssertEqual(real(RAMDResults.locate(near: run)), real(inResults))
    }

    // MARK: - the tool

    func testAnalyzeReportsTauAndPlotsTheSurvivalCurve() throws {
        let dir = try tempDir("tool")
        let traj = dir.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        try timesCSV(rows(seed: 11, times: [100, 200, 300, 400])
                     + rows(seed: 22, times: [300, 400, 500, 600]))
            .write(to: dir.appendingPathComponent("tramd_times.csv"), atomically: true, encoding: .utf8)
        try "t_ps,seed,fraction_bound\n0,11,1.0\n300,11,0.5\n600,11,0.0\n"
            .write(to: dir.appendingPathComponent("tramd_survival.csv"), atomically: true, encoding: .utf8)

        func result(_ i: Int, frameTime: Double? = nil) throws -> ToolResult {
            try KineticsTool.analyze(frame: frame(),
                                     context: AnalysisContext(frameIndex: i, sourceURL: traj),
                                     params: .init(frameTime_ps: frameTime))
        }

        let r0 = try result(0, frameTime: 100)
        XCTAssertTrue(value(r0, "Residence time τ")!.hasPrefix("300 [95 % CI"), value(r0, "Residence time τ")!)
        XCTAssertEqual(value(r0, "τ per seed"), "11: 200 · 22: 400")
        XCTAssertEqual(value(r0, "Replicas"), "8 over 2 seeds (4/4, 4/4 dissociated)")
        XCTAssertTrue(value(r0, "Censored")!.hasPrefix("0 of 8"), value(r0, "Censored")!)
        XCTAssertTrue(value(r0, "k_off (relative)")!.contains("rank order"))
        XCTAssertEqual(r0.scalar, 1.0)                        // t = 0: everything still bound
        XCTAssertTrue(r0.notes.contains(RAMDResults.koffCaveat))

        // frame 3 × 100 ps = 300 ps: 100, 200 and both 300s have gone — 4 of 8 left
        let r3 = try result(3, frameTime: 100)
        XCTAssertEqual(r3.scalar!, 0.5, accuracy: 1e-12)
        XCTAssertTrue(value(r3, "Bound at t = 300 ps") != nil, r3.summary.map { $0.label }.description)
        XCTAssertTrue(r3.notes.contains { $0.contains("frame 3 × 100 ps") })

        // no frame interval: the frame index walks the survival file's own axis (0, 300, 600)
        let axis = try result(1)
        XCTAssertEqual(axis.scalar!, 0.5, accuracy: 1e-12)
        XCTAssertTrue(axis.notes.contains { $0.contains("survival-file") })
        // past the end of that axis it clamps rather than throwing
        XCTAssertEqual(try result(99).scalar!, 0.0, accuracy: 1e-12)
    }

    func testAnalyzeSaysSoWhenTauIsUndefined() throws {
        let dir = try tempDir("censored")
        let traj = dir.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        try timesCSV(rows(seed: 1, times: [100, 2000, 2000], censored: [false, true, true]))
            .write(to: dir.appendingPathComponent("tramd_times.csv"), atomically: true, encoding: .utf8)
        let r = try KineticsTool.analyze(frame: frame(),
                                         context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                         params: .init())
        XCTAssertTrue(value(r, "Residence time τ")!.contains("only 1 of 3 replicas"), value(r, "Residence time τ")!)
        XCTAssertEqual(value(r, "k_off (relative)"), "n/a — τ undefined")
        XCTAssertTrue(r.notes.contains { $0.contains("lower bound") })
    }

    func testMissingSideFileIsAMissingRequirement() throws {
        let dir = try tempDir("empty")
        let traj = dir.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        let ctx = AnalysisContext(frameIndex: 0, sourceURL: traj)
        XCTAssertThrowsError(try KineticsTool.analyze(frame: frame(), context: ctx, params: .init())) {
            XCTAssertEqual($0 as? AnalysisError, .missingRequirement(.sideFile))
        }
        XCTAssertTrue(KineticsTool.searchNote(context: ctx, params: .init()).contains(dir.path))
        // no source URL at all: same error, different explanation
        XCTAssertThrowsError(try KineticsTool.analyze(frame: frame(), context: AnalysisContext(), params: .init())) {
            XCTAssertEqual($0 as? AnalysisError, .missingRequirement(.sideFile))
        }
        XCTAssertTrue(KineticsTool.searchNote(context: AnalysisContext(), params: .init()).contains("set csvPath"))
    }

    func testToolMetadataMatchesTheContract() {
        let meta = AnyAnalysisTool(KineticsTool.self).metadata
        XCTAssertEqual(meta.id, "kinetics_tramd")
        XCTAssertEqual(meta.title, "Unbinding kinetics (τRAMD)")
        XCTAssertEqual(meta.category, .adhesionBinding)
        XCTAssertEqual(Set(meta.functions), [.scalar, .timeSeries])
        XCTAssertEqual(meta.requirements, [.sideFile])
        XCTAssertFalse(meta.supportsStridedPreview)
    }
}
