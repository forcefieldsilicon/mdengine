import XCTest
@testable import LAMMPSCore

/// Synthetic pulls only — the real run's data stays in the study repo.
final class PullOffEnergeticsTests: XCTestCase {

    // MARK: - synthetic side files

    private struct SeedSpec {
        let seed: Int, peakRow: Int, peak_kJ: Double, ruptureRow: Int
    }
    private static let rows = 20
    private static let dx = 0.05          // nm per row, com == ref (clean ramp)
    private static let dt = 5.0           // ps per row

    /// Piecewise-linear force: linear rise to the peak, flat 10 % tail. Linear
    /// segments make the trapezoid exact, so CSV work and the tool's own
    /// trapezoid must agree to machine precision.
    private func force(_ s: SeedSpec, _ i: Int) -> Double {
        i <= s.peakRow ? s.peak_kJ * Double(i) / Double(s.peakRow) : s.peak_kJ * 0.1
    }

    private func work(_ s: SeedSpec, upTo n: Int) -> Double {
        var w = 0.0
        for i in 1...max(1, n) where n > 0 { w += 0.5 * (force(s, i) + force(s, i - 1)) * Self.dx }
        return n > 0 ? w : 0
    }

    private func csv(_ specs: [SeedSpec]) -> String {
        var out = "seed,time_ps,ref_disp_nm,com_disp_nm,com_lateral_nm,force_kJ_mol_nm,force_pN,"
            + "work_kJ_mol,n_contacts_total,potential_kJ_mol,temperature_K\n"
        for s in specs {
            for i in 0..<Self.rows {
                let f = force(s, i)
                let c = i < s.ruptureRow ? 4 + i % 3 : 0
                let cells: [Double] = [Double(s.seed), Double(i) * Self.dt, Double(i) * Self.dx,
                                       Double(i) * Self.dx, 0.03, f, f * ForceCurve.kJmolNmInPN,
                                       work(s, upTo: i), Double(c), -2000, 300]
                out += cells.map { String(format: "%.14g", $0) }.joined(separator: ",") + "\n"
            }
        }
        return out
    }

    private static let specs = [SeedSpec(seed: 101, peakRow: 12, peak_kJ: 200, ruptureRow: 14),
                                SeedSpec(seed: 102, peakRow: 10, peak_kJ: 150, ruptureRow: 12),
                                SeedSpec(seed: 103, peakRow: 8, peak_kJ: 100, ruptureRow: 10)]

    private func tempDir(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulloff-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    private func configJSON(velocity: Double, k: Double = 1000, seeds: [Int]) -> String {
        """
        {"pull_velocity_A_per_ns": \(velocity), "spring_k_kJ_mol_nm2": \(k),
         "report_interval_ps": \(Self.dt), "seeds": \(seeds)}
        """
    }

    /// A run directory: config.json at the top, results/ with the CSV and a
    /// stand-in trajectory — the protocol's real layout.
    @discardableResult
    private func makeRun(_ dir: URL, velocity: Double, specs: [SeedSpec]) throws -> URL {
        let results = dir.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try configJSON(velocity: velocity, seeds: specs.map { $0.seed })
            .write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try csv(specs).write(to: results.appendingPathComponent("force_curve.csv"),
                             atomically: true, encoding: .utf8)
        let traj = results.appendingPathComponent("trajectory.xyz")
        try "1\nframe 0\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        return traj
    }

    private func frame() -> Frame { Frame(atoms: [Arv(element: "C", x: 0, y: 0, z: 0)]) }

    // MARK: - parsing and energetics

    func testParseGroupsSeedsAndComputesFStarWorkAndRupture() throws {
        let curve = ForceCurve.parse(csv(Self.specs))
        XCTAssertEqual(curve.seeds.map { $0.seed }, [101, 102, 103])
        XCTAssertEqual(curve.rowCount, 60)
        XCTAssertEqual(curve.seed(101)?.count, 20)
        XCTAssertEqual(curve.seed(101)?.reportInterval_ps, 5.0)

        for spec in Self.specs {
            let seed = try XCTUnwrap(curve.seed(spec.seed))
            let peak = try XCTUnwrap(Energetics.ruptureForce(seed))
            XCTAssertEqual(peak.index, spec.peakRow)
            XCTAssertEqual(peak.Fstar, spec.peak_kJ * ForceCurve.kJmolNmInPN, accuracy: 1e-9)

            let w = try XCTUnwrap(Energetics.workOfSeparation(seed))
            XCTAssertEqual(w.csv, work(spec, upTo: Self.rows - 1), accuracy: 1e-9)
            XCTAssertEqual(w.csv, w.trapezoid, accuracy: 1e-6)   // linear ramp: exact

            XCTAssertEqual(Energetics.ruptureIndex(seed), spec.ruptureRow)
        }
        // contacts that never break → no rupture index
        let never = SeedSpec(seed: 7, peakRow: 5, peak_kJ: 50, ruptureRow: Self.rows + 1)
        XCTAssertNil(Energetics.ruptureIndex(try XCTUnwrap(ForceCurve.parse(csv([never])).seed(7))))
    }

    func testParseToleratesMissingAndExtraColumns() {
        let text = """
        time_ps,force_kJ_mol_nm,junk
        0,0,hello
        5,60.5,hello
        10,nan,hello
        15,121,hello
        """
        let curve = ForceCurve.parse(text)
        XCTAssertEqual(curve.seeds.count, 1)                     // no seed column → one group
        let s = curve.seeds[0]
        XCTAssertEqual(s.count, 3)                               // the NaN row is dropped
        XCTAssertEqual(s.force_pN[1], 60.5 * ForceCurve.kJmolNmInPN, accuracy: 1e-9)
        XCTAssertEqual(s.comDisp, [0, 0, 0])
        XCTAssertEqual(Energetics.ruptureIndex(s), 0)            // no contacts column → zero from row 0
    }

    // MARK: - locating side files

    func testLocateFindsCSVBesideTrajectoryAndInResultsSibling() throws {
        let flat = try tempDir("flat")
        let traj = flat.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        XCTAssertNil(ForceCurve.locate(near: traj))
        let beside = flat.appendingPathComponent("force_curve.csv")
        try csv(Self.specs).write(to: beside, atomically: true, encoding: .utf8)
        XCTAssertEqual(ForceCurve.locate(near: traj)?.path, beside.path)

        // run layout: trajectory in results/, CSV in results/, config one up
        let run = try tempDir("run")
        let inResults = try makeRun(run, velocity: 50, specs: Self.specs)
        func real(_ u: URL?) -> String? { u?.resolvingSymlinksInPath().path }   // /var → /private/var
        XCTAssertEqual(ForceCurve.locate(near: inResults)?.lastPathComponent, "force_curve.csv")
        XCTAssertEqual(real(RunConfig.locate(near: inResults)),
                       real(run.appendingPathComponent("config.json")))
        // …and from the run directory itself, via the results* sibling
        XCTAssertEqual(real(ForceCurve.locate(near: run)),
                       real(run.appendingPathComponent("results/force_curve.csv")))

        let cfg = try RunConfig.load(XCTUnwrap(RunConfig.locate(near: inResults)))
        XCTAssertEqual(cfg.pullVelocity_A_per_ns, 50)
        XCTAssertEqual(cfg.seeds, [101, 102, 103])
        XCTAssertEqual(cfg.springK_pN_per_nm!, 1000 * ForceCurve.kJmolNmInPN, accuracy: 1e-9)
        XCTAssertEqual(cfg.loadingRate_pN_per_s!, 1000 * ForceCurve.kJmolNmInPN * 50 * 1e8, accuracy: 1)
    }

    // MARK: - Bell–Evans

    func testBellEvansRecoversKoffAndXBeta() throws {
        let xBeta = 0.35, koff0 = 1e-3, kT = Energetics.kT_pN_nm(300)
        let rates = [1e2, 1e3, 1e4, 1e5]
        let points = rates.map { r in (loadingRate: r, Fstar: (kT / xBeta) * log(r * xBeta / (koff0 * kT))) }
        let fit = try XCTUnwrap(Energetics.bellEvans(points: points))
        XCTAssertEqual(fit.xBeta_nm, xBeta, accuracy: 1e-9)
        XCTAssertEqual(fit.koff0 / koff0, 1.0, accuracy: 1e-6)
        XCTAssertEqual(fit.slope, kT / xBeta, accuracy: 1e-9)

        XCTAssertNil(Energetics.bellEvans(points: Array(points.prefix(2))))          // 2 rates
        XCTAssertNil(Energetics.bellEvans(points: [points[0], points[0], points[1]])) // 2 distinct
    }

    // MARK: - Jarzynski

    func testJarzynskiGatesAtTenPulls() throws {
        let kT = Energetics.kT_kJ_per_mol(300)
        XCTAssertNil(Energetics.jarzynski(works: Array(repeating: 42.0, count: 9), kT: kT))
        let j = try XCTUnwrap(Energetics.jarzynski(works: Array(repeating: 42.0, count: 10), kT: kT))
        XCTAssertEqual(j.deltaF, 42.0, accuracy: 1e-9)               // identical works: ΔF = W
        XCTAssertEqual(j.secondOrderCumulant, 42.0, accuracy: 1e-9)  // …and zero variance

        // two-valued set: both estimators have closed forms
        let works = Array(repeating: 40.0, count: 5) + Array(repeating: 60.0, count: 5)
        let k = try XCTUnwrap(Energetics.jarzynski(works: works, kT: kT))
        let expected = -kT * log(0.5 * (exp(-40 / kT) + exp(-60 / kT)))
        XCTAssertEqual(k.deltaF, expected, accuracy: 1e-9)
        XCTAssertEqual(k.secondOrderCumulant, 50 - 100 / (2 * kT), accuracy: 1e-9)
    }

    // MARK: - the tool

    private func value(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.value
    }

    func testResultCarriesTheWholeForceCurveAsASeries() throws {
        let run = try tempDir("series")
        let traj = try makeRun(run, velocity: 50, specs: Self.specs)
        let r = try PullOffEnergeticsTool.analyze(frame: frame(),
                                                  context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                                  params: .init())
        let series = try XCTUnwrap(r.series)
        XCTAssertEqual(series.count, Self.rows, "one series point per CSV row under row alignment")
        XCTAssertEqual(series[12]!, 200 * ForceCurve.kJmolNmInPN, accuracy: 1e-6)   // the peak row
        XCTAssertEqual(series[0], 0)
        XCTAssertEqual(r.seriesLabel, "Spring force (pN)")
        // Inspector-side state, not part of the JSON contract (MCP/CLI output unchanged).
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(json.contains("\"series\""))
    }

    func testAnalyzeAtFrameZeroAndAtThePeak() throws {
        let run = try tempDir("tool")
        let traj = try makeRun(run, velocity: 50, specs: Self.specs)
        func result(_ i: Int) throws -> ToolResult {
            try PullOffEnergeticsTool.analyze(frame: frame(),
                                              context: AnalysisContext(frameIndex: i, sourceURL: traj),
                                              params: .init())
        }
        let r0 = try result(0)
        XCTAssertEqual(value(r0, "Time"), "0")
        XCTAssertEqual(value(r0, "Spring force"), "0")
        XCTAssertEqual(value(r0, "Contacts"), "4")
        XCTAssertEqual(r0.scalar, 0)
        XCTAssertEqual(value(r0, "Seed"), "101 (3 in this file)")
        XCTAssertEqual(value(r0, "Pull velocity"), "50")
        XCTAssertEqual(value(r0, "Rupture frame"), "14 (t = 70 ps)")
        XCTAssertEqual(value(r0, "Rupture force F*"), "332.1 (frame 12)")
        XCTAssertTrue(value(r0, "F* across seeds")!.hasPrefix("median 249.1 [IQR 166.1–332.1], n = 3"),
                      value(r0, "F* across seeds")!)
        XCTAssertTrue(value(r0, "Work of separation W")!.contains("trapezoid"))
        // gates: one velocity, and a screen rate → neither fit is offered
        XCTAssertEqual(value(r0, "Bell–Evans"), "n/a: 1 velocity — need ≥ 3")
        XCTAssertTrue(value(r0, "Free energy")!.hasPrefix("work, single pull — not a free energy"))
        XCTAssertTrue(r0.notes.contains(PullOffEnergeticsTool.rateCaveat))
        XCTAssertTrue(r0.notes.contains { $0.contains("frame i ↔ CSV row i") })

        let peak = try result(12)
        XCTAssertEqual(peak.scalar!, 200 * ForceCurve.kJmolNmInPN, accuracy: 1e-6)
        XCTAssertEqual(value(peak, "Time"), "60")
        XCTAssertEqual(value(peak, "COM displacement"), "0.6")
        XCTAssertEqual(value(peak, "Rupture force F*"), "332.1 (frame 12)")

        // past the end of the CSV under row alignment
        XCTAssertThrowsError(try result(Self.rows)) {
            guard case AnalysisError.notApplicable(let why)? = $0 as? AnalysisError else {
                return XCTFail("notApplicable expected, got \($0)")
            }
            XCTAssertTrue(why.contains("past the end"), why)
        }
        // and by time, frame 3 is the row at 15 ps
        let byTime = try PullOffEnergeticsTool.analyze(
            frame: frame(), context: AnalysisContext(frameIndex: 3, sourceURL: traj),
            params: .init(seed: 102, frameAlignment: .time))
        XCTAssertEqual(value(byTime, "Time"), "15")
        XCTAssertEqual(value(byTime, "Seed"), "102 (3 in this file)")
    }

    func testMissingSideFileIsAMissingRequirement() throws {
        let dir = try tempDir("empty")
        let traj = dir.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        let ctx = AnalysisContext(frameIndex: 0, sourceURL: traj)
        XCTAssertThrowsError(try PullOffEnergeticsTool.analyze(frame: frame(), context: ctx, params: .init())) {
            XCTAssertEqual($0 as? AnalysisError, .missingRequirement(.sideFile))
        }
        XCTAssertTrue(PullOffEnergeticsTool.searchNote(context: ctx, params: .init()).contains(dir.path))
        // no source URL at all: same error, different explanation
        XCTAssertThrowsError(try PullOffEnergeticsTool.analyze(frame: frame(), context: AnalysisContext(),
                                                              params: .init())) {
            XCTAssertEqual($0 as? AnalysisError, .missingRequirement(.sideFile))
        }
    }

    func testBellEvansRowAppearsWithThreeVelocities() throws {
        let root = try tempDir("rates")
        var dirs: [String] = []
        var traj: URL!
        for (n, v) in [50.0, 10.0, 1.0].enumerated() {
            let run = root.appendingPathComponent("run\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            // slower pull → lower rupture force, as Bell–Evans expects
            let specs = Self.specs.map { SeedSpec(seed: $0.seed, peakRow: $0.peakRow,
                                                  peak_kJ: $0.peak_kJ - Double(n) * 20,
                                                  ruptureRow: $0.ruptureRow) }
            let t = try makeRun(run, velocity: v, specs: specs)
            if n == 0 { traj = t } else { dirs.append(run.path) }
        }
        let r = try PullOffEnergeticsTool.analyze(
            frame: frame(), context: AnalysisContext(frameIndex: 0, sourceURL: traj),
            params: .init(runDirs: dirs))
        let be = try XCTUnwrap(value(r, "Bell–Evans"))
        XCTAssertTrue(be.contains("x_β") && be.contains("3 velocities"), be)
        XCTAssertTrue(r.notes.contains { $0.contains("Pooled 3 runs") })
        // only 3 pulls at ≤ 1 Å/ns → still not a free energy
        XCTAssertTrue(value(r, "Free energy")!.contains("3 pulls at ≤ 1 Å/ns"), value(r, "Free energy")!)
    }

    func testCRLFFileParsesLikeLF() {
        let lf = "seed,time_ps,ref_disp_nm,com_disp_nm,force_kJ_mol_nm,force_pN,work_kJ_mol,n_contacts_total\n"
               + "1,0.0,0.0,0.0,0.0,0.0,0.0,3\n1,5.0,0.025,0.02,60.0,99.6,1.0,2\n1,10.0,0.05,0.04,0.0,0.0,1.5,0\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let a = ForceCurve.parse(lf), b = ForceCurve.parse(crlf)
        XCTAssertEqual(a.rowCount, 3)
        XCTAssertEqual(b.rowCount, 3, "CRLF (python csv default) must parse like LF")
        XCTAssertEqual(a.seeds.first?.force_pN, b.seeds.first?.force_pN)
    }
}
