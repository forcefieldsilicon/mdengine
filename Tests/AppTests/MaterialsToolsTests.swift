//
//  MaterialsToolsTests.swift — RDF/coordination, MSD/diffusion and the thermo
//  stress–strain tool, all against fixtures with an analytic answer.
//
//  The point of each fixture is that the right answer is known before the code
//  runs: an ideal gas HAS g(r) = 1, a perfect fcc lattice HAS its first shell
//  at a/√2 with twelve neighbours, a Gaussian random walk HAS D = σ²/(2Δt),
//  and a hand-made log HAS the modulus that was written into it.
//

import XCTest
@testable import LAMMPSCore

final class MaterialsToolsTests: XCTestCase {

    // MARK: - RDF

    /// Uniform random points in a periodic cell: the definition of "no
    /// structure", so g(r) must be 1 everywhere the statistics are good.
    func testIdealGasHasFlatGOfR() throws {
        let n = 2000, L = 40.0
        var rng = Fixtures.SplitMix64(seed: 0xA11CE)
        let atoms = (0..<n).map { _ in
            Arv(element: "Ar", x: rng.uniform() * L, y: rng.uniform() * L, z: rng.uniform() * L)
        }
        let frame = Frame(atoms: atoms, box: SimulationBox(lo: .zero, hi: SIMD3(L, L, L)))

        // 0.2 Å bins, not the tool's default 0.05 Å: 2000 atoms put ~700 pairs
        // in a 0.05 Å bin near r = 3 Å, so bin-level Poisson noise alone is
        // ±6 % and the worst of ~100 bins lands outside ±0.15 about half the
        // time. Four times the bin width halves the noise. (Verified across
        // six seeds: worst |g − 1| in [3, 8] Å is 0.04–0.11 here, 0.13–0.19
        // at 0.05 Å.)
        let rc = 5.0
        let params = RDFTool.Parameters(rMax: 10, bins: 50, coordinationCutoff: rc)
        let r = try RDFTool.analyze(frame: frame, context: AnalysisContext(), params: params)
        let profile = try XCTUnwrap(r.profile)

        for (i, centre) in profile.centers.enumerated() where centre >= 3 && centre <= 8 {
            XCTAssertEqual(profile.values[i], 1.0, accuracy: 0.15,
                           "g(r) at r = \(centre) Å should be 1 for an ideal gas")
        }

        // N(r) = ρ·4/3πr³, with ρ = (N−1)/V because an atom is not its own neighbour.
        let rho = Double(n - 1) / (L * L * L)
        let expected = rho * 4.0 / 3.0 * Double.pi * rc * rc * rc
        let measured = try XCTUnwrap(Double(r.summary.first { $0.label == "Mean coordination" }!.value))
        XCTAssertEqual(measured, expected, accuracy: 0.10 * expected)
        XCTAssertEqual(r.field?.values.count, n)
    }

    /// A perfect fcc crystal: the first shell is at a/√2 with exactly twelve
    /// neighbours, and the tool has to find both without being told the radius.
    func testFccFirstShellAndCoordination() throws {
        let a = 4.05
        let frame = Fixtures.fcc(a: a, cells: 6)
        let r = try RDFTool.analyze(frame: frame, context: AnalysisContext(),
                                    params: .init(rMax: 10, bins: 200))

        let expectedPeak = a / 2.0.squareRoot()
        let peak = try XCTUnwrap(r.scalar)
        XCTAssertEqual(peak, expectedPeak, accuracy: 0.01 * expectedPeak,
                       "first peak should be a/√2 = \(expectedPeak) Å")

        let coordination = try XCTUnwrap(Double(r.summary.first { $0.label == "Mean coordination" }!.value))
        XCTAssertEqual(coordination, 12, accuracy: 1e-9)
        let firstMin = try XCTUnwrap(Double(r.summary.first { $0.label == "First minimum" }!.value))
        XCTAssertGreaterThan(firstMin, expectedPeak)
        XCTAssertLessThan(firstMin, a)                      // below the second shell
        XCTAssertTrue(r.field?.values.allSatisfy { $0 == 12 } ?? false)
        XCTAssertTrue(r.notes.isEmpty, "a well-formed periodic frame needs no caveats: \(r.notes)")

        // Naming the species explicitly must not change a single-element result.
        let named = try RDFTool.analyze(frame: frame, context: AnalysisContext(),
                                        params: .init(speciesA: "Al", speciesB: "Al", rMax: 10, bins: 200))
        XCTAssertEqual(named.scalar!, peak, accuracy: 1e-12)
        XCTAssertThrowsError(try RDFTool.analyze(frame: frame, context: AnalysisContext(),
                                                 params: .init(speciesA: "Cu")))
    }

    /// Without a cell there is no density to normalise by, so the tool falls
    /// back to the bounding box and must say so rather than pretend.
    func testRDFWithoutABoxSaysSo() throws {
        let r = try RDFTool.analyze(frame: Fixtures.fccSlabOpenBoundary(),
                                    context: AnalysisContext(), params: .init(rMax: 6, bins: 120))
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("No box") }, "\(r.notes)")
        XCTAssertNotNil(r.profile)
    }

    // MARK: - Diffusion

    /// A Gaussian random walk with per-frame, per-component width σ. Returned
    /// both unwrapped (the truth) and wrapped into the cell (what a dump looks
    /// like), so unwrapping can be checked against a known answer.
    private struct Walk {
        let truth: [[SIMD3<Double>]]        // frames × atoms, never wrapped
        let frames: Trajectory              // wrapped, with box + timestep
        let dt_ps: Double
        /// MSD of the truth, relative to frame 0.
        func msd(_ f: Int) -> Double {
            let n = truth[0].count
            var sum = 0.0
            for i in 0..<n {
                let d = truth[f][i] - truth[0][i]
                sum += d.x * d.x + d.y * d.y + d.z * d.z
            }
            return sum / Double(n)
        }
    }

    /// 6000 atoms, not a few hundred: the MSD of N independent walkers has a
    /// relative spread of √(6/N)/3, and the slope through it inherits it, so a
    /// 500-atom walk recovers D to ±10 % depending only on the seed (measured:
    /// −12.7 % to +5.6 % over seven seeds). At 6000 every seed tried lands
    /// inside ±1.3 %, which is a test of the estimator rather than of luck.
    private func randomWalk(atoms: Int = 6000, frames: Int = 30, sigma: Double = 0.4,
                            L: Double = 12, drift: SIMD3<Double> = .zero,
                            seed: UInt64 = 0x5EED) -> Walk {
        var rng = Fixtures.SplitMix64(seed: seed)
        let box = SimulationBox(lo: .zero, hi: SIMD3(L, L, L))
        var current = (0..<atoms).map { _ in
            SIMD3(rng.uniform() * L, rng.uniform() * L, rng.uniform() * L)
        }
        var truth = [current]
        var trajectory: Trajectory = []
        for f in 0..<frames {
            if f > 0 {
                for i in 0..<atoms {
                    current[i] += SIMD3(rng.normal() * sigma, rng.normal() * sigma, rng.normal() * sigma) + drift
                }
                truth.append(current)
            }
            // The dump only ever sees wrapped coordinates.
            let wrapped = truth[f].map { box.wrap($0) }
            trajectory.append(Frame(atoms: wrapped.map { Arv(element: "Ar", x: $0.x, y: $0.y, z: $0.z) },
                                    box: box, timestep: f * 1000))
        }
        return Walk(truth: truth, frames: trajectory, dt_ps: 1.0)
    }

    /// D = slope/6 with MSD = 6Dt (three dimensions). For a walk of Gaussian
    /// width σ per component per step, MSD = 3σ²·n = 6D·(n·Δt), so
    /// D = σ²/(2Δt) — the convention this tool reports in.
    func testDiffusionRecoversTheAnalyticCoefficient() throws {
        let sigma = 0.4
        let walk = randomWalk(sigma: sigma)
        let expectedD = sigma * sigma / (2 * walk.dt_ps)

        let series = try DiffusionTool.series(trajectory: walk.frames, referenceIndex: 0,
                                              params: .init(timestep_fs: 1.0))
        XCTAssertEqual(series.diffusion_A2_per_ps, expectedD, accuracy: 0.05 * expectedD,
                       "Einstein fit should recover σ²/2Δt = \(expectedD) Å²/ps")
        XCTAssertGreaterThan(series.slopeStandardError, 0)
        XCTAssertEqual(series.fitFrom, 6)                          // 20 % of 30 frames
        XCTAssertEqual(series.time_ps[10] - series.time_ps[0], 10, accuracy: 1e-12)

        // Unwrapping is exact: the MSD from the wrapped dump must equal the
        // MSD of the trajectory that was never wrapped, frame for frame.
        for f in 0..<walk.frames.count {
            XCTAssertEqual(series.msd[f], walk.msd(f), accuracy: 1e-9, "frame \(f)")
        }

        let last = walk.frames.count - 1
        let context = AnalysisContext(frameIndex: last, referenceFrame: walk.frames[0],
                                      referenceFrameIndex: 0, trajectory: walk.frames,
                                      trajectoryGeneration: 0)
        let r = try DiffusionTool.analyze(frame: walk.frames[last], context: context,
                                          params: .init(timestep_fs: 1.0))
        XCTAssertEqual(r.scalar!, walk.msd(last), accuracy: 1e-9)
        XCTAssertEqual(r.field?.values.count, walk.frames[last].count)
        let dRow = try XCTUnwrap(r.summary.first { $0.unit == "cm²/s" })
        let dCm2 = try XCTUnwrap(Double(dRow.value.split(separator: " ").first!))
        XCTAssertEqual(dCm2, expectedD * 1e-4, accuracy: 0.05 * expectedD * 1e-4)
    }

    /// With a drift big enough to cross the cell, a wrapped dump read without
    /// unwrapping saturates — which is the bug this option exists to avoid.
    func testUnwrappingIsWhatMakesTheWrappedDumpUsable() throws {
        // 500 atoms is plenty here: the assertion is about the box, not about
        // the precision of an average.
        let walk = randomWalk(atoms: 500, L: 12, drift: SIMD3(0.5, 0, 0))
        let last = walk.frames.count - 1
        let truth = walk.msd(last)
        XCTAssertGreaterThan(truth, 150)                            // ~29 × 0.5 Å of drift, squared

        let unwrapped = try DiffusionTool.series(trajectory: walk.frames, referenceIndex: 0,
                                                 params: .init(unwrap: true))
        XCTAssertEqual(unwrapped.msd[last], truth, accuracy: 1e-9)

        let raw = try DiffusionTool.series(trajectory: walk.frames, referenceIndex: 0,
                                           params: .init(unwrap: false))
        XCTAssertLessThan(raw.msd[last], 0.4 * truth,
                          "without unwrapping the displacement is capped by the box")
    }

    func testDiffusionNeedsAReferenceFrameAndCachesPerGeneration() throws {
        let walk = randomWalk(atoms: 100, frames: 8)
        XCTAssertThrowsError(try DiffusionTool.analyze(frame: walk.frames[1],
                                                       context: AnalysisContext(frameIndex: 1),
                                                       params: .init())) { error in
            XCTAssertEqual(error as? AnalysisError, .missingRequirement(.referenceFrame))
        }
        func run(_ generation: Int) throws -> ToolResult {
            let c = AnalysisContext(frameIndex: 3, referenceFrame: walk.frames[0], referenceFrameIndex: 0,
                                    trajectory: walk.frames, trajectoryGeneration: generation)
            return try DiffusionTool.analyze(frame: walk.frames[3], context: c, params: .init())
        }
        let first = try run(77)
        let cached = try run(77)
        XCTAssertEqual(first.scalar!, cached.scalar!, accuracy: 0)
        XCTAssertEqual(first.summary, cached.summary)

        // One frame only: MSD still reports, D does not pretend to exist.
        let single = AnalysisContext(frameIndex: 1, referenceFrame: walk.frames[0], referenceFrameIndex: 0)
        let lone = try DiffusionTool.analyze(frame: walk.frames[1], context: single, params: .init())
        XCTAssertNotNil(lone.scalar)
        XCTAssertFalse(lone.summary.contains { $0.unit == "cm²/s" })
        XCTAssertTrue(lone.notes.contains { $0.contains("Only one frame") }, "\(lone.notes)")
    }

    // MARK: - Thermo

    /// Two runs, one warning mid-table, one `Loop time` per run — and a
    /// stress–strain curve whose modulus is exactly 70 GPa by construction:
    /// σ = E·ε up to 2 % strain, then a perfectly plastic plateau.
    private static let modulus_GPa = 70.0

    private func syntheticLog() -> String {
        var out = """
        LAMMPS (2 Aug 2023)
        Reading data file ...
        Per MPI rank memory allocation (min/avg/max) = 3.1 | 3.1 | 3.1 Mbytes
        Step Temp PotEng Press Lx Pxx

        """
        // Run 1: equilibration at fixed length, zero stress.
        for step in stride(from: 0, through: 400, by: 100) {
            out += "\(step) 300.0 -1234.5 12.0 10.0 0\n"
            if step == 200 { out += "WARNING: Bond/angle/dihedral extent > half of periodic box (src/domain.cpp:936)\n" }
        }
        out += "Loop time of 1.234 on 1 procs for 400 steps with 500 atoms\n"
        out += "\nPer MPI rank memory allocation (min/avg/max) = 3.1 | 3.1 | 3.1 Mbytes\n"
        out += "Step Temp PotEng Press Lx Pxx\n"
        // Run 2: tension. Stress in bar = −σ(GPa)/1e-4.
        for k in 0...15 {
            let strain = Double(k) * 0.002
            let sigma = Self.modulus_GPa * min(strain, 0.02)          // linear, then plateau
            let step = 400 + k * 100
            out += String(format: "%d 300.0 -1200.0 5.0 %.6f %.4f\n", step, 10.0 * (1 + strain), -sigma / 1e-4)
        }
        out += "Loop time of 9.876 on 1 procs for 1500 steps with 500 atoms\n"
        out += "Total wall time: 0:00:11\n"
        return out
    }

    func testLammpsLogParsesBlocksColumnsAndCRLF() throws {
        let text = syntheticLog()
        let log = LammpsLog.parse(text)
        XCTAssertEqual(log.blocks.count, 2)
        XCTAssertEqual(log.blocks[0].columns, ["Step", "Temp", "PotEng", "Press", "Lx", "Pxx"])
        XCTAssertEqual(log.blocks[0].rows.count, 5)                  // the WARNING is not a row
        XCTAssertEqual(log.blocks[1].rows.count, 16)
        XCTAssertEqual(log.blocks[0].loopTime_s, 1.234)
        XCTAssertEqual(log.blocks[1].loopTime_s, 9.876)
        XCTAssertEqual(log.commonColumns, ["Step", "Temp", "PotEng", "Press", "Lx", "Pxx"])
        XCTAssertEqual(log.column("Step")?.count, 21)
        XCTAssertEqual(log.column("Step")?.last, 1900)
        XCTAssertNil(log.column("Enthalpy"))
        XCTAssertEqual(log.rowBlockIndex.last, 1)

        // "\r\n" is one Character, so a naive split on "\n" would see one line.
        let crlf = LammpsLog.parse(text.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(crlf, log)
        XCTAssertTrue(LammpsLog.parse("no thermo here\njust prose\n").isEmpty)
    }

    func testStressStrainRecoversTheModulusAndAlignsByStep() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mde-thermo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("log.lammps")
        try syntheticLog().write(to: logURL, atomically: true, encoding: .utf8)

        let curve = try XCTUnwrap(ThermoTool.stressStrain(LammpsLog.parse(syntheticLog()), elasticStrain: 0.02))
        XCTAssertEqual(curve.axis, "x")
        XCTAssertEqual(curve.youngsModulus_GPa, Self.modulus_GPa,
                       accuracy: 0.01 * Self.modulus_GPa)
        XCTAssertEqual(curve.maxStress_GPa, Self.modulus_GPa * 0.02, accuracy: 1e-9)
        XCTAssertEqual(curve.strain.last!, 0.030, accuracy: 1e-9)

        // A frame at step 900 must read the thermo row for step 900 (strain 1 %).
        let frame = Frame(atoms: [Arv(element: "Al", x: 0, y: 0, z: 0)], timestep: 900)
        let context = AnalysisContext(frameIndex: 99,                 // deliberately wrong index
                                      sourceURL: dir.appendingPathComponent("dump.lammpstrj"))
        let r = try ThermoTool.analyze(frame: frame, context: context, params: .init())
        XCTAssertEqual(r.summary.first { $0.label == "Step" }?.value, "900")
        XCTAssertEqual(r.summary.first { $0.label == "Temp" }?.value, "300")
        XCTAssertEqual(r.summary.first { $0.label == "Run" }?.value, "2 of 2")
        let strain = try XCTUnwrap(Double(r.summary.first { $0.label == "Strain (this frame)" }!.value))
        XCTAssertEqual(strain, 1.0, accuracy: 1e-6)                   // per cent
        XCTAssertEqual(r.scalar!, Self.modulus_GPa * 0.01, accuracy: 1e-9)   // stress follows playback
        let e = try XCTUnwrap(Double(r.summary.first { $0.label == "Young's modulus E" }!.value))
        XCTAssertEqual(e, Self.modulus_GPa, accuracy: 0.01 * Self.modulus_GPa)

        // alignBy index takes row i for frame i, and without stress–strain the
        // scalar falls back to the first requested y column.
        let byIndex = try ThermoTool.analyze(
            frame: frame,
            context: AnalysisContext(frameIndex: 2, sourceURL: dir.appendingPathComponent("dump.lammpstrj")),
            params: .init(yColumns: ["Temp", "Nope"], stressStrain: false, alignBy: "index"))
        XCTAssertEqual(byIndex.summary.first { $0.label == "Step" }?.value, "200")
        XCTAssertEqual(byIndex.scalar!, 300, accuracy: 1e-9)
        XCTAssertTrue(byIndex.notes.contains { $0.contains("Nope") }, "\(byIndex.notes)")
    }

    func testThermoWithoutALogIsAMissingSideFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mde-nolog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let frame = Frame(atoms: [Arv(element: "Al", x: 0, y: 0, z: 0)], timestep: 0)

        for context in [AnalysisContext(), AnalysisContext(sourceURL: dir.appendingPathComponent("dump.xyz"))] {
            XCTAssertThrowsError(try ThermoTool.analyze(frame: frame, context: context, params: .init())) {
                XCTAssertEqual($0 as? AnalysisError, .missingRequirement(.sideFile))
            }
        }
    }
}
