import XCTest
@testable import LAMMPSCore

/// Validation for the Conformation tool. Every fixture is analytic: a rigid
/// motion (RMSD must vanish), one wiggling atom (only its RMSF may be nonzero),
/// a cube of equal masses (Rg in closed form), three well-separated basins
/// (known cluster populations), a one-dimensional excursion (PC1 = all of the
/// variance) and ideal backbone geometry (DSSP letters).
final class ConformationToolTests: XCTestCase {

    // MARK: - Fixtures

    /// A deterministic 20-atom 3-D scatter — no RNG, so the numbers repeat.
    private func cloud(_ n: Int = 20) -> [SIMD3<Double>] {
        (0..<n).map { (i: Int) -> SIMD3<Double> in
            let x: Double = Double(i % 5) * 3.0
            let y: Double = Double((i / 5) % 2) * 3.0 + Double(i % 3) * 0.7
            let z: Double = Double(i / 10) * 3.0 + Double(i % 4) * 0.4
            return SIMD3<Double>(x, y, z)
        }
    }

    private func frame(_ points: [SIMD3<Double>], element: String = "C") -> Frame {
        Frame(atoms: points.map { Arv(element: element, x: $0.x, y: $0.y, z: $0.z) })
    }

    /// Rotation by `deg` about a normalised axis (Rodrigues), as a Mat3.
    private func rotation(deg: Double, axis: SIMD3<Double>) -> Mat3 {
        let a = axis / (axis * axis).sum().squareRoot()
        let t = deg * .pi / 180, c = cos(t), s = sin(t)
        return Mat3(SIMD3(c + a.x * a.x * (1 - c), a.x * a.y * (1 - c) - a.z * s, a.x * a.z * (1 - c) + a.y * s),
                    SIMD3(a.y * a.x * (1 - c) + a.z * s, c + a.y * a.y * (1 - c), a.y * a.z * (1 - c) - a.x * s),
                    SIMD3(a.z * a.x * (1 - c) - a.y * s, a.z * a.y * (1 - c) + a.x * s, c + a.z * a.z * (1 - c)))
    }

    private func row(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.value
    }

    /// "-1.23 (99.4 % of variance)" → 99.4
    private func percentage(_ text: String?) -> Double? {
        guard let piece = text?.split(separator: "(").last?.split(separator: "%").first else { return nil }
        return Double(piece.trimmingCharacters(in: .whitespaces))
    }

    private func context(_ traj: Trajectory, index: Int = 0, generation: Int = 1) -> AnalysisContext {
        AnalysisContext(frameIndex: index, trajectory: traj, trajectoryGeneration: generation)
    }

    // MARK: - (a) superposition

    func testRigidMotionSuperposesToZeroRMSD() throws {
        let reference = cloud()
        let r = rotation(deg: 37, axis: SIMD3(0.3, -0.8, 0.5))
        let shift = SIMD3<Double>(12, -5, 7)
        let moved = reference.map { r * $0 + shift }

        let fit = try XCTUnwrap(Superposition.fit(mobile: moved, reference: reference))
        XCTAssertEqual(fit.rmsd, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(Superposition.rmsdNoFit(moved, reference), 5)
        // The recovered rotation is the inverse of the applied one.
        for p in reference { XCTAssertLessThan(((fit.apply(r * p + shift) - p) * (fit.apply(r * p + shift) - p)).sum(), 1e-18) }

        // Weighted: only the first half is fitted, and only it has to match.
        var displaced = moved
        displaced[15] += SIMD3(9, 9, 9)
        let weights = (0..<reference.count).map { $0 < 10 ? 1.0 : 0.0 }
        let weighted = try XCTUnwrap(Superposition.fit(mobile: displaced, reference: reference, weights: weights))
        XCTAssertEqual(weighted.rmsd, 0, accuracy: 1e-9)
        XCTAssertNil(Superposition.fit(mobile: [], reference: []))
    }

    func testToolReportsFittedAndUnfittedRMSD() throws {
        let reference = frame(cloud())
        let r = rotation(deg: 20, axis: SIMD3(0, 0, 1))
        let moved = frame(cloud().map { r * $0 + SIMD3(3, 0, 0) })
        let result = try ConformationTool.analyze(
            frame: moved, context: context([reference, moved], index: 1),
            params: .init(selection: "all", quantity: "displacement"))
        XCTAssertEqual(result.scalar!, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(Double(row(result, "RMSD without fit")!)!, 1)
        XCTAssertEqual(row(result, "Selection"), "all (20 atoms)")
        XCTAssertEqual(result.field?.name, "displacement")
        for v in result.field!.values { XCTAssertLessThan(v, 1e-5) }
    }

    // MARK: - (b) RMSF

    func testRMSFIsolatesTheAtomThatMoves() throws {
        let base = cloud()
        let wiggle = [0.0, 0.5, 0.0, -0.5, 0.0]
        let frames = wiggle.map { d -> Frame in
            var points = base
            points[7].x += d
            return frame(points)
        }
        let result = try ConformationTool.analyze(
            frame: frames[0], context: context(frames), params: .init(selection: "all"))
        let values = try XCTUnwrap(result.field?.values)
        XCTAssertEqual(result.field?.name, "rmsf")
        XCTAssertEqual(Double(values[7]), 0.316, accuracy: 0.02)      // √(2·0.25/5)
        for (i, v) in values.enumerated() where i != 7 { XCTAssertLessThan(v, 0.05) }
        XCTAssertLessThan(Double(row(result, "Mean RMSF")!)!, 0.05)
    }

    // MARK: - (c) radius of gyration

    func testRadiusOfGyrationOfACube() throws {
        let d = 2.0
        let corners: [SIMD3<Double>] = [-1, 1].flatMap { x in [-1.0, 1].flatMap { y in
            [-1.0, 1].map { z in SIMD3(Double(x) * d, y * d, z * d) } } }
        let f = frame(corners)                                   // equal masses (C)
        XCTAssertEqual(ConformationTool.radiusOfGyration(f, Array(0..<8)), d * 3.0.squareRoot(), accuracy: 1e-12)
        let result = try ConformationTool.analyze(frame: f, context: AnalysisContext(),
                                                  params: .init(selection: "all"))
        XCTAssertEqual(Double(row(result, "Radius of gyration")!)!, 3.464, accuracy: 1e-3)
        XCTAssertTrue(result.notes.contains { $0.contains("One frame only") })
    }

    // MARK: - (d) clustering

    /// Three basins, populations 4 / 3 / 2, separated far beyond the jitter.
    private func threeBasins() -> Trajectory {
        let base = cloud(12)
        func conformer(_ shift: SIMD3<Double>, jitter: Double) -> Frame {
            var points = base
            for i in 6..<12 { points[i] += shift }
            for i in points.indices { points[i] += SIMD3(jitter, -jitter, jitter * 0.5) }
            return frame(points)
        }
        let a = SIMD3<Double>(0, 0, 0), b = SIMD3<Double>(8, 0, 0), c = SIMD3<Double>(0, 8, 6)
        var traj: Trajectory = []
        for (shift, n) in [(a, 4), (b, 3), (c, 2)] {
            for k in 0..<n { traj.append(conformer(shift, jitter: Double(k) * 0.002)) }
        }
        return traj
    }

    func testKMedoidsFindsThreeBasinsWithTheRightPopulations() throws {
        let traj = threeBasins()
        let result = try ConformationTool.analyze(
            frame: traj[0], context: context(traj, generation: 11),
            params: .init(selection: "all", clusterCount: 3))
        XCTAssertEqual(row(result, "Cluster populations"), "4, 3, 2")
        XCTAssertEqual(row(result, "Cluster of this frame"), "1 of 3")

        let last = try ConformationTool.analyze(
            frame: traj[8], context: context(traj, index: 8, generation: 11),
            params: .init(selection: "all", clusterCount: 3))
        XCTAssertEqual(row(last, "Cluster of this frame"), "3 of 3")
    }

    func testGromosCutoffClusteringSplitsTheSameBasins() throws {
        let traj = threeBasins()
        let result = try ConformationTool.analyze(
            frame: traj[0], context: context(traj, generation: 12),
            params: .init(selection: "all", clusterRMSDCutoff: 1.0))
        XCTAssertEqual(row(result, "Cluster populations"), "4, 3, 2")
        XCTAssertTrue(result.notes.contains { $0.contains("Gromos") })
    }

    func testLongTrajectorySubsamplesTheDistanceMatrix() throws {
        let base = cloud(6)
        let traj: Trajectory = (0..<450).map { t in
            var points = base
            points[2].x += t < 300 ? 0.0 : 6.0                 // two basins, 300 / 150
            return frame(points)
        }
        let result = try ConformationTool.analyze(
            frame: traj[449], context: context(traj, index: 449, generation: 31),
            params: .init(selection: "all", clusterCount: 2))
        XCTAssertTrue(result.notes.contains { $0.contains("every 2ᵗʰ frame") })
        let populations = row(result, "Cluster populations")!.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        XCTAssertEqual(populations.reduce(0, +), 450)
        XCTAssertEqual(populations, [300, 150])
        XCTAssertEqual(row(result, "Cluster of this frame"), "2 of 2")
    }

    // MARK: - (e) PCA

    func testPCAOnAOneDimensionalExcursion() throws {
        let base = cloud()
        let traj = (-2...2).map { t -> Frame in
            var points = base
            points[0].x += Double(t) * 0.2
            points[3].y -= Double(t) * 0.2
            points[5].z += (Double(t * t) - 2) * 0.004      // a second, tiny direction
            return frame(points)
        }
        let result = try ConformationTool.analyze(
            frame: traj[4], context: context(traj, index: 4, generation: 21),
            params: .init(selection: "all", pcaComponents: 2))
        let pc1 = try XCTUnwrap(percentage(row(result, "PC1 projection")))
        XCTAssertGreaterThan(pc1, 98)
        XCTAssertLessThan(try XCTUnwrap(percentage(row(result, "PC2 projection"))), 2)

        // And the raw solver on data that is exactly one direction: rank 1, so
        // one component comes back and it carries the whole variance,
        // ⟨t²⟩·|d|² = 4·6 = 24.
        let direction = (0..<9).map { Double($0 % 3) - 1 }
        let x = (-3...3).map { t in direction.map { $0 * Double(t) } }
        let (vectors, values) = ConformationTool.principalComponents(x, count: 2)
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(values[0], 24, accuracy: 1e-9)
        XCTAssertEqual(abs(vectors[0][0]), 1 / 6.0.squareRoot(), accuracy: 1e-9)
    }

    // MARK: - (f) DSSP

    func testDSSPOnAnIdealAlphaHelix() throws {
        let helix = ProteinFixtures.alphaHelix(residues: 12)
        let ss = try XCTUnwrap(DSSP.analyze(frame: helix))
        XCTAssertEqual(ss.residueCount, 12)
        // The two terminal residues cannot be helix by construction (a minimal
        // helix needs two consecutive 4-turns), so the interior is the test.
        XCTAssertGreaterThanOrEqual(ss.fraction(["H"], in: 1..<11), 0.9)
        XCTAssertGreaterThanOrEqual(ss.fraction(SecondaryStructure.helixLetters), 0.8)
        XCTAssertEqual(ss.fraction(SecondaryStructure.strandLetters), 0)

        let result = try ConformationTool.analyze(frame: helix, context: AnalysisContext(),
                                                  params: .init(selection: "backbone", quantity: "dssp"))
        XCTAssertEqual(result.field?.name, "dssp")
        if case .categorical(let entries)? = result.field?.palette {
            XCTAssertEqual(entries.count, 4)
        } else { XCTFail("categorical palette expected") }
        XCTAssertEqual(result.field?.values.filter { $0 == 1 }.count, 40)   // 10 residues × 4 atoms
        XCTAssertTrue(row(result, "Secondary structure")!.hasPrefix("83 % helix"))
    }

    func testDSSPOnAnAntiparallelSheet() throws {
        // Two ideal strands related by the sheet's two-fold axis. This is an
        // idealisation, not a relaxed hairpin, so the assertion is relaxed:
        // the interior residues of both strands must register as E.
        let sheet = ProteinFixtures.antiparallelSheet()
        let ss = try XCTUnwrap(DSSP.analyze(frame: sheet))
        XCTAssertEqual(ss.residueCount, 16)
        XCTAssertGreaterThanOrEqual(ss.fraction(SecondaryStructure.strandLetters), 0.5)
        XCTAssertEqual(ss.fraction(SecondaryStructure.helixLetters), 0)
        XCTAssertGreaterThanOrEqual(ss.letters[2...6].filter { $0 == "E" }.count, 4)
        XCTAssertGreaterThanOrEqual(ss.letters[10...14].filter { $0 == "E" }.count, 4)
    }

    func testDSSPNeedsAtomNames() throws {
        let bare = ProteinFixtures.helixWithoutNames()
        XCTAssertNil(DSSP.analyze(frame: bare))
        let result = try ConformationTool.analyze(frame: bare, context: AnalysisContext(),
                                                  params: .init(selection: "ca", quantity: "dssp"))
        XCTAssertTrue(result.notes.contains { $0.contains("DSSP needs atom names") })
        XCTAssertTrue(result.notes.contains { $0.contains("fell back to heavy atoms") })
        XCTAssertNil(result.field)
        XCTAssertEqual(row(result, "Selection"), "heavy (48 atoms)")      // 12 × (N, CA, C, O)
    }

    // MARK: - (g) caching

    func testTrajectoryLevelResultsAreCachedPerGeneration() throws {
        ConformationTool.resetCache()
        let traj = threeBasins()
        let params = ConformationTool.Parameters(selection: "all", clusterCount: 3)
        for i in 0..<5 {
            _ = try ConformationTool.analyze(frame: traj[i], context: context(traj, index: i, generation: 7),
                                             params: params)
        }
        XCTAssertEqual(ConformationTool.trajectoryComputations, 1)

        // A new generation (file reloaded, live follow) recomputes; so does a
        // parameter change. An ephemeral generation (0) is never cached.
        _ = try ConformationTool.analyze(frame: traj[0], context: context(traj, generation: 8), params: params)
        XCTAssertEqual(ConformationTool.trajectoryComputations, 2)
        _ = try ConformationTool.analyze(frame: traj[0], context: context(traj, generation: 8),
                                         params: .init(selection: "all", clusterCount: 2))
        XCTAssertEqual(ConformationTool.trajectoryComputations, 3)
        for _ in 0..<2 {
            _ = try ConformationTool.analyze(frame: traj[0], context: context(traj, generation: 0), params: params)
        }
        XCTAssertEqual(ConformationTool.trajectoryComputations, 5)
        ConformationTool.resetCache()
    }

    // MARK: - (h) fixture geometry, and the metadata contract

    func testBackboneBuilderReproducesItsOwnTorsions() throws {
        let atoms = ProteinFixtures.backbone(residues: 6, phi: -57, psi: -47)
        for i in 1..<5 {
            let phi = ProteinFixtures.dihedral(atoms[(i - 1) * 4 + 2].p, atoms[i * 4].p,
                                               atoms[i * 4 + 1].p, atoms[i * 4 + 2].p)
            let psi = ProteinFixtures.dihedral(atoms[i * 4].p, atoms[i * 4 + 1].p,
                                               atoms[i * 4 + 2].p, atoms[(i + 1) * 4].p)
            XCTAssertEqual(phi, -57, accuracy: 1e-6)
            XCTAssertEqual(psi, -47, accuracy: 1e-6)
        }
        // The signature of an ideal α-helix: the i → i+4 backbone hydrogen bond
        // O(i)···N(i+4) at ≈ 3 Å, and Cα(i)–Cα(i+3) at ≈ 5 Å.
        for i in 0..<2 {
            let on = ProteinFixtures.norm(atoms[(i + 4) * 4].p - atoms[i * 4 + 3].p)
            XCTAssertEqual(on, 3.0, accuracy: 0.35)
        }
        let cas = atoms.filter { $0.name == "CA" }.map { $0.p }
        XCTAssertEqual(ProteinFixtures.norm(cas[3] - cas[0]), 5.1, accuracy: 0.4)
    }

    func testSelectionAndMetadata() throws {
        let helix = ProteinFixtures.alphaHelix()
        XCTAssertEqual(AtomSelection.select("ca", in: helix).indices.count, 12)
        XCTAssertEqual(AtomSelection.select("backbone", in: helix).indices.count, 48)
        XCTAssertEqual(AtomSelection.select("heavy", in: helix).indices.count, 48)
        XCTAssertNotNil(AtomSelection.select("nonsense", in: helix).note)

        let meta = AnyAnalysisTool(ConformationTool.self).metadata
        XCTAssertEqual(meta.id, "conformation")
        XCTAssertEqual(meta.category, .structureOrder)
        XCTAssertFalse(meta.supportsStridedPreview)
        XCTAssertTrue(meta.requirements.isEmpty)

        // Parameters survive the JSON boundary MCP/CLI use.
        let params = ConformationTool.Parameters(selection: "backbone", quantity: "dssp",
                                                 clusterCount: 5, clusterRMSDCutoff: 1.5,
                                                 pcaComponents: 3,
                                                 group: .label(name: "chain", values: ["A"]))
        let json = try JSONEncoder().encode(params)
        XCTAssertEqual(try JSONDecoder().decode(ConformationTool.Parameters.self, from: json), params)
        let scoped = try AnyAnalysisTool(ConformationTool.self)
            .analyze(frame: ProteinFixtures.antiparallelSheet(), context: AnalysisContext(),
                     parametersJSON: json)
        XCTAssertEqual(row(scoped, "Selection"), "backbone (32 atoms)")   // chain A only
    }
}
