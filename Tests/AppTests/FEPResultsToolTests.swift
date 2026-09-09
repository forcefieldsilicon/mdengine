import XCTest
@testable import LAMMPSCore

/// Synthetic networks only — the same shape `rbfe_openfe.py analyze` writes
/// (schema mdengine.fep.results/1); no study data lives in this repo.
final class FEPResultsToolTests: XCTestCase {

    // MARK: - fixtures

    /// Four ligands, five edges, one edge that failed its gates and one cycle
    /// that does not close — the cases the tool exists to surface.
    private static let full = """
    {"schema": "mdengine.fep.results/1", "demo": true, "forcefield": "openff-2.2.0",
     "settings": {"solvent": "tip3p", "n_repeats": 3, "lambda_windows": 11, "prod_ns": 1.0},
     "edges": [
       {"ligA": "ligA", "ligB": "ligB", "ddG_kcal": -0.68, "ddG_err": 0.31,
        "dG_solvent": -3.08, "dG_complex": -3.76, "overlap_min": 0.09, "converged": true, "notes": ""},
       {"ligA": "ligB", "ligB": "ligC", "ddG_kcal": 1.51, "ddG_err": 0.28,
        "dG_solvent": -3.39, "dG_complex": -1.88, "overlap_min": 0.11, "converged": true, "notes": ""},
       {"ligA": "ligC", "ligB": "ligA", "ddG_kcal": -0.83, "ddG_err": 0.35,
        "dG_solvent": -3.13, "dG_complex": -3.96, "overlap_min": 0.14, "converged": true, "notes": ""},
       {"ligA": "ligA", "ligB": "ligD", "ddG_kcal": 0.95, "ddG_err": 0.44,
        "dG_solvent": -1.95, "dG_complex": -1.0, "overlap_min": 0.02, "converged": false,
        "notes": "overlap min 0.020 < 0.03 — add lambda windows"},
       {"ligA": "ligB", "ligB": "ligD", "ddG_kcal": 0.48, "ddG_err": 0.26,
        "dG_solvent": -3.22, "dG_complex": -2.74, "overlap_min": 0.18, "converged": true, "notes": ""}],
     "ligands": [
       {"name": "ligB", "dG_abs_kcal": -0.647, "dG_abs_err": 0.52, "rank": 1},
       {"name": "ligA", "dG_abs_kcal": -0.197, "dG_abs_err": 0.524, "rank": 2},
       {"name": "ligD", "dG_abs_kcal": 0.071, "dG_abs_err": 0.531, "rank": 3},
       {"name": "ligC", "dG_abs_kcal": 0.773, "dG_abs_err": 0.529, "rank": 4}],
     "cycles": [
       {"ligands": ["ligA", "ligD", "ligB"], "closure_kcal": 1.15, "closure_err": 0.6},
       {"ligands": ["ligA", "ligC", "ligB"], "closure_kcal": 0.0, "closure_err": 0.55}],
     "absolute_method": "weighted least squares (local)",
     "flags": ["DEMO DATA — synthetic numbers, not a simulation result"],
     "provenance": {"openfe": "1.3.1", "openmm": "8.2.0", "openff": "0.16.4",
                    "gufe": null, "cinnabar": null, "rdkit": "2024.09.4",
                    "date": "2026-09-08T00:00:00Z", "host": "pod-1"}}
    """

    /// A producer that wrote only what it had: no settings, no cycles, no
    /// provenance, no per-edge diagnostics.
    private static let sparse = """
    {"edges": [{"ligA": "x", "ligB": "y", "ddG_kcal": -1.25},
               {"ligA": "y", "ligB": "z"}],
     "ligands": [{"name": "x"}, {"name": "y", "dG_abs_kcal": -2.0}]}
    """

    private func tempDir(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("fep-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    /// Run directory in the pipeline's own layout: results.json in `results/`
    /// beside the trajectory, unless `beside` puts it next to the file.
    @discardableResult
    private func makeRun(_ dir: URL, json: String, beside: Bool = false) throws -> URL {
        let results = dir.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let traj = (beside ? dir : results).appendingPathComponent("trajectory.xyz")
        try "1\nframe 0\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        try json.write(to: (beside ? dir : results).appendingPathComponent("results.json"),
                       atomically: true, encoding: .utf8)
        return traj
    }

    private func frame() -> Frame { Frame(atoms: [Arv(element: "C", x: 0, y: 0, z: 0)]) }

    private func value(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.value
    }

    private func decode(_ s: String) throws -> FEPResults {
        try JSONDecoder().decode(FEPResults.self, from: Data(s.utf8))
    }

    // MARK: - model

    func testDecodesTheSchemaAndRanksLigands() throws {
        let r = try decode(Self.full)
        XCTAssertEqual(r.schema, "mdengine.fep.results/1")
        XCTAssertTrue(r.isDemo)
        XCTAssertEqual(r.edges.count, 5)
        XCTAssertEqual(r.ranked.map { $0.name }, ["ligB", "ligA", "ligD", "ligC"])
        XCTAssertEqual(r.cycles?.count, 2)
        XCTAssertEqual(r.provenance?.openfe, "1.3.1")
        XCTAssertNil(r.provenance?.gufe)                       // explicit JSON null
        XCTAssertEqual(r.settings?["n_repeats"]?.text, "3")    // int-valued double prints as an int
        XCTAssertEqual(r.settings?["solvent"]?.text, "tip3p")
        XCTAssertEqual(r.edges[0].name, "ligA→ligB")
    }

    func testMissingOptionalFieldsDecodeAndRankByEnergy() throws {
        let r = try decode(Self.sparse)
        XCTAssertNil(r.schema)
        XCTAssertFalse(r.isDemo)
        XCTAssertNil(r.cycles)
        XCTAssertNil(r.edges[1].ddG_kcal)
        XCTAssertNil(r.edges[1].converged)
        // no ranks anywhere: order falls back to ΔG, and a nil ΔG sorts last
        XCTAssertEqual(r.ranked.map { $0.name }, ["y", "x"])
    }

    // MARK: - tool

    func testSummaryCarriesRankingEdgesAndCycles() throws {
        let dir = try tempDir("full")
        let traj = try makeRun(dir, json: Self.full)
        let r = try FEPResultsTool.analyze(frame: frame(),
                                           context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                           params: .init())
        XCTAssertEqual(value(r, "Force field"), "openff-2.2.0")
        XCTAssertEqual(value(r, "Network"), "4 ligands, 5 edges — DEMO DATA")
        XCTAssertTrue(value(r, "Settings")!.contains("lambda_windows 11"), value(r, "Settings")!)
        XCTAssertTrue(value(r, "Provenance")!.contains("openfe 1.3.1"))
        XCTAssertEqual(value(r, "#1  ligB"), "-0.65 ± 0.52")
        XCTAssertEqual(value(r, "Cycle ligA–ligD–ligB"), "1.15 ± 0.60  ✗")
        XCTAssertEqual(value(r, "Cycle ligA–ligC–ligB"), "0.00 ± 0.55")
        // ranked sort: ligB's edges first (rank 1), then ligA's, then ligD's
        let edgeRows = r.summary.filter { $0.label.contains("edge ") }
        XCTAssertEqual(edgeRows.count, 5)
        XCTAssertEqual(edgeRows[0].label, "▸ edge 0: ligA→ligB")
        XCTAssertTrue(edgeRows[0].value.hasPrefix("ΔΔG -0.68 ± 0.31, overlap 0.090"), edgeRows[0].value)
        XCTAssertTrue(edgeRows[3].value.contains("NOT CONVERGED"), edgeRows[3].value)
    }

    func testNotesFlagUnconvergedLowOverlapAndOpenCycles() throws {
        let dir = try tempDir("flags")
        let traj = try makeRun(dir, json: Self.full)
        let r = try FEPResultsTool.analyze(frame: frame(),
                                           context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                           params: .init())
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("DEMO DATA") })
        XCTAssertTrue(r.notes.contains { $0.contains("frame axis is the edge index") })
        let bad = try XCTUnwrap(r.notes.first { $0.hasPrefix("Edge ligA→ligD") })
        XCTAssertTrue(bad.contains("did not converge") && bad.contains("overlap min 0.020 < 0.03"), bad)
        XCTAssertTrue(r.notes.contains { $0.contains("ligA–ligD–ligB closes at 1.15") })
        XCTAssertFalse(r.notes.contains { $0.contains("ligA–ligC–ligB closes") })   // that one closes
        XCTAssertEqual(r.notes.filter { $0.hasPrefix("Edge ") }.count, 1)
        XCTAssertTrue(r.notes.contains { $0.contains("relative to the network mean") })
    }

    func testScalarIsTheEdgeDdGAtTheFrameIndexAndFollowsTheSort() throws {
        let dir = try tempDir("scalar")
        let traj = try makeRun(dir, json: Self.full, beside: true)
        func scalar(_ i: Int, _ sort: FEPResultsTool.SortBy) throws -> Double? {
            try FEPResultsTool.analyze(frame: frame(),
                                       context: AnalysisContext(frameIndex: i, sourceURL: traj),
                                       params: .init(sortBy: sort)).scalar
        }
        XCTAssertEqual(try scalar(0, .rank), -0.68)            // ligA→ligB: touches rank-1 ligB, first by name
        XCTAssertEqual(try scalar(0, .ddG), -0.83)             // most negative ΔΔG first
        XCTAssertEqual(try scalar(4, .ddG), 1.51)
        XCTAssertEqual(try scalar(0, .error), 0.95)            // largest σ (0.44) first
        // past the last edge is a clear refusal, not a clamped lie
        XCTAssertThrowsError(try scalar(5, .rank)) {
            guard case .notApplicable(let why)? = $0 as? AnalysisError else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("past the end of the network (5 edges)"), why)
        }
    }

    func testLocatesResultsJSONBesideTheTrajectoryAndInAResultsDirectory() throws {
        let inResults = try tempDir("loc1")
        let trajA = try makeRun(inResults, json: Self.full)                    // both in results/
        XCTAssertEqual(FEPResults.locate(near: trajA)?.deletingLastPathComponent().lastPathComponent,
                       "results")
        // trajectory at the top, results.json in the results/ child
        let sibling = try tempDir("loc2")
        let results = sibling.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try Self.full.write(to: results.appendingPathComponent("results.json"),
                            atomically: true, encoding: .utf8)
        let trajB = sibling.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: trajB, atomically: true, encoding: .utf8)
        XCTAssertEqual(FEPResults.locate(near: trajB)?.standardizedFileURL.resolvingSymlinksInPath(),
                       results.appendingPathComponent("results.json").resolvingSymlinksInPath())
        // explicit path wins over the search
        let r = try FEPResultsTool.analyze(
            frame: frame(), context: AnalysisContext(frameIndex: 0, sourceURL: trajB),
            params: .init(jsonPath: results.appendingPathComponent("results.json").path))
        XCTAssertEqual(value(r, "Force field"), "openff-2.2.0")
    }

    func testMissingSideFileIsAMissingRequirement() throws {
        let dir = try tempDir("empty")
        let traj = dir.appendingPathComponent("trajectory.xyz")
        try "1\nf\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        let ctx = AnalysisContext(frameIndex: 0, sourceURL: traj)
        XCTAssertThrowsError(try FEPResultsTool.analyze(frame: frame(), context: ctx, params: .init())) {
            XCTAssertEqual($0 as? AnalysisError, .missingRequirement(.sideFile))
        }
        XCTAssertTrue(FEPResultsTool.searchNote(context: ctx, params: .init()).contains(dir.path))
        // no source URL at all: same error, different explanation
        XCTAssertThrowsError(try FEPResultsTool.analyze(frame: frame(), context: AnalysisContext(),
                                                        params: .init())) {
            XCTAssertEqual($0 as? AnalysisError, .missingRequirement(.sideFile))
        }
        XCTAssertTrue(FEPResultsTool.searchNote(context: AnalysisContext(), params: .init())
            .contains("set jsonPath"))
    }

    func testAnEmptyNetworkIsNotApplicable() throws {
        let dir = try tempDir("noedges")
        let traj = try makeRun(dir, json: #"{"schema": "mdengine.fep.results/1", "edges": []}"#)
        XCTAssertThrowsError(try FEPResultsTool.analyze(
            frame: frame(), context: AnalysisContext(frameIndex: 0, sourceURL: traj), params: .init())) {
            guard case .notApplicable(let why)? = $0 as? AnalysisError else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("no edges"), why)
        }
    }

    func testSparseFileStillRenders() throws {
        let dir = try tempDir("sparse")
        let traj = try makeRun(dir, json: Self.sparse)
        let r = try FEPResultsTool.analyze(frame: frame(),
                                           context: AnalysisContext(frameIndex: 1, sourceURL: traj),
                                           params: .init())
        XCTAssertEqual(value(r, "Force field"), "unknown")
        XCTAssertEqual(value(r, "Network"), "2 ligands, 2 edges")
        XCTAssertNil(value(r, "Settings"))
        XCTAssertEqual(value(r, "#?  x"), "— ± —")
        XCTAssertNil(r.scalar)                                  // second edge has no estimate
        XCTAssertFalse(r.notes.contains { $0.hasPrefix("Edge ") })  // nothing known, nothing claimed
    }
}
