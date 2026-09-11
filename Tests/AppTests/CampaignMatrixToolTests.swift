import XCTest
@testable import LAMMPSCore

/// Synthetic campaigns only — the shape `delivery/module1/campaign.py matrix` writes
/// (schema dsuite.matrix/1); no study data lives in this repo.
final class CampaignMatrixToolTests: XCTestCase {

    // MARK: - fixtures

    /// Three ligands × two receptors. Two cells of the target column are one tier
    /// (bands overlap), one is separated; two cells are unprepared; one selectivity
    /// ratio is real and one sits inside its own band.
    private static let full = """
    {"schema": "dsuite.matrix/1", "campaign": "panel-test", "protocol": "afm-pull-tethered",
     "quantity": "afm_adhesion_force_pN", "label": "adhesion force (pN)", "direction": "lower",
     "unit": "pN", "ligands": ["a", "b", "c"], "receptors": ["tgt", "off"],
     "primary_receptor": "tgt", "n_cells": 6, "n_delivered": 4, "coverage": 0.667,
     "resolution": {"median_band": 8.0, "min_resolvable_difference": 16.0,
                    "rule": "separated iff |dv| > u_i + u_j, with u = IQR/2 over seeds"},
     "cells": {
       "a__tgt": {"cell": "a__tgt", "ligand": "a", "receptor": "tgt", "state": "ok",
                  "value": -190.0, "uncertainty": 8.0, "n": 3, "n_attempted": 3, "tier": "A", "unit": "pN"},
       "b__tgt": {"cell": "b__tgt", "ligand": "b", "receptor": "tgt", "state": "ok",
                  "value": -185.0, "uncertainty": 8.0, "n": 3, "n_attempted": 3, "tier": "A", "unit": "pN"},
       "c__tgt": {"cell": "c__tgt", "ligand": "c", "receptor": "tgt", "state": "ok",
                  "value": -100.0, "uncertainty": 5.0, "n": 3, "n_attempted": 3, "tier": "B", "unit": "pN"},
       "a__off": {"cell": "a__off", "ligand": "a", "receptor": "off", "state": "ok",
                  "value": -50.0, "uncertainty": 5.0, "n": 3, "n_attempted": 3, "tier": "A", "unit": "pN"},
       "b__off": {"cell": "b__off", "ligand": "b", "receptor": "off", "state": "needs-prep",
                  "value": null, "uncertainty": null, "n": 0, "n_attempted": 0},
       "c__off": {"cell": "c__off", "ligand": "c", "receptor": "off", "state": "failed",
                  "value": null, "uncertainty": null, "n": 0, "n_attempted": 3}},
     "columns": {"tgt": ["a__tgt", "b__tgt", "c__tgt"], "off": ["a__off"]},
     "selectivity": {
       "a:tgt/off": {"ligand": "a", "vs": "off", "mode": "ratio", "value": 3.8,
                     "uncertainty": 0.42, "resolved": true, "null": 1.0}},
     "compromises": [
       {"id": "screen-rate-velocity", "severity": "high", "what": "retraction is 10^6x faster than an AFM",
        "effect_on_results": "rank-order only", "to_complete": "several velocities"},
       {"id": "matrix-incomplete-grid", "severity": "high", "what": "4 of 6 cells delivered",
        "effect_on_results": "tiers over the delivered subset", "to_complete": "prep the rest"},
       {"id": "replicates-n3", "severity": "low", "what": "3 seeds", "effect_on_results": "IQR/2 band",
        "to_complete": "config-only: more seeds"}],
     "ok": true}
    """

    /// A campaign that has only just been initialised: no delivered cell anywhere,
    /// no resolution, no selectivity — exactly when someone opens the viewer.
    private static let empty = """
    {"schema": "dsuite.matrix/1", "campaign": "fresh", "quantity": "afm_adhesion_force_pN",
     "direction": "lower", "ligands": ["a"], "receptors": ["tgt"], "primary_receptor": "tgt",
     "n_cells": 1, "n_delivered": 0, "coverage": 0.0,
     "resolution": {"median_band": null, "min_resolvable_difference": null, "rule": "x"},
     "cells": {"a__tgt": {"cell": "a__tgt", "ligand": "a", "receptor": "tgt",
                          "state": "needs-prep", "value": null, "uncertainty": null}},
     "columns": {"tgt": []}, "selectivity": {}, "compromises": [], "ok": false}
    """

    /// Higher-is-stronger, and a selectivity that is not one.
    private static let higher = """
    {"schema": "dsuite.matrix/1", "campaign": "tau", "quantity": "residence_time_tau",
     "label": "residence time tau (ns)", "direction": "higher", "unit": "ns",
     "ligands": ["a", "b"], "receptors": ["tgt", "off"], "primary_receptor": "tgt",
     "n_cells": 4, "n_delivered": 3, "coverage": 0.75,
     "cells": {
       "a__tgt": {"cell": "a__tgt", "ligand": "a", "receptor": "tgt", "state": "ok",
                  "value": 12.0, "uncertainty": 3.0, "n": 3, "tier": "A"},
       "b__tgt": {"cell": "b__tgt", "ligand": "b", "receptor": "tgt", "state": "ok",
                  "value": 2.0, "uncertainty": 0.5, "n": 3, "tier": "B"},
       "a__off": {"cell": "a__off", "ligand": "a", "receptor": "off", "state": "ok",
                  "value": 11.0, "uncertainty": 4.0, "n": 3, "tier": "A"},
       "b__off": {"cell": "b__off", "ligand": "b", "receptor": "off", "state": "prepared",
                  "value": null, "uncertainty": null}},
     "columns": {"tgt": ["a__tgt", "b__tgt"], "off": ["a__off"]},
     "selectivity": {"a:tgt/off": {"ligand": "a", "vs": "off", "mode": "ratio", "value": 1.09,
                                   "uncertainty": 0.48, "resolved": false, "null": 1.0}},
     "compromises": [], "ok": true}
    """

    private func tempDir(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("campaign-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    /// A campaign directory in the producer's layout: matrix.json at the root, the
    /// anchor down in cells/<cell>-s1/results/ where a seed's trajectory actually lives.
    @discardableResult
    private func makeCampaign(_ dir: URL, json: String) throws -> URL {
        let seed = dir.appendingPathComponent("cells/a__tgt-s1/results", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        let traj = seed.appendingPathComponent("trajectory.xyz")
        try "1\nframe 0\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        try json.write(to: dir.appendingPathComponent("matrix.json"), atomically: true, encoding: .utf8)
        return traj
    }

    private func frame() -> Frame { Frame(atoms: [Arv(element: "C", x: 0, y: 0, z: 0)]) }
    private func value(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.value
    }
    private func decode(_ s: String) throws -> CampaignMatrix {
        try JSONDecoder().decode(CampaignMatrix.self, from: Data(s.utf8))
    }

    // MARK: - model

    func testDecodesTheSchemaAndReadsSemanticsFromTheFile() throws {
        let m = try decode(Self.full)
        XCTAssertEqual(m.schema, "dsuite.matrix/1")
        XCTAssertEqual(m.protocolName, "afm-pull-tethered")     // `protocol` is a Swift keyword
        XCTAssertTrue(m.lowerIsStronger)
        XCTAssertEqual(m.displayUnit, "pN")
        XCTAssertEqual(m.primaryColumn, "tgt")
        XCTAssertEqual(m.cells.count, 6)
        XCTAssertEqual(m.tierCount, 2)                          // A and B on the primary column
        XCTAssertEqual(m.column("tgt").map(\.ligand), ["a", "b", "c"])
        XCTAssertEqual(m.cell("a", "off")?.value, -50.0)
        // direction comes from the file, not from this side
        XCTAssertFalse(try decode(Self.higher).lowerIsStronger)
    }

    func testUndeliveredCellsAreAbsentNotZero() throws {
        let m = try decode(Self.full)
        let pending = m.undelivered()
        XCTAssertEqual(pending.map(\.cell), ["b__off", "c__off"])
        XCTAssertEqual(pending.map(\.state), ["needs-prep", "failed"])
        for c in pending {
            XCTAssertNil(c.value)                               // never 0.0
            XCTAssertFalse(c.delivered)
        }
        XCTAssertEqual(m.column("off").count, 1)                // the walked column excludes them
        XCTAssertEqual(m.undelivered("off").count, 2)
    }

    func testFindsMatrixJSONFromASeedDirectoryDeepInTheCampaign() throws {
        let dir = try tempDir("locate")
        let traj = try makeCampaign(dir, json: Self.full)
        let found = CampaignMatrix.locate(near: traj)
        XCTAssertEqual(found?.standardizedFileURL.path,
                       dir.appendingPathComponent("matrix.json").standardizedFileURL.path)
    }

    // MARK: - tool

    func testSummaryCarriesCoverageResolutionTheGridAndSelectivity() throws {
        let dir = try tempDir("full")
        let traj = try makeCampaign(dir, json: Self.full)
        let r = try CampaignMatrixTool.analyze(frame: frame(),
                                               context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                               params: .init())
        XCTAssertEqual(value(r, "Campaign"), "panel-test · afm-pull-tethered")
        XCTAssertEqual(value(r, "Coverage"), "4 of 6 cells (67%)")
        XCTAssertTrue(value(r, "Quantity")!.contains("stronger = lower"), value(r, "Quantity")!)
        XCTAssertTrue(value(r, "Resolution")!.contains("16.00 are not resolved"), value(r, "Resolution")!)
        XCTAssertEqual(value(r, "Not measured"), "1 failed, 1 needs-prep")
        // a ligand row shows the state where there is no number — never a zero
        XCTAssertEqual(value(r, "a"), "tgt [A] -190.00 ± 8.00 (n=3)   |   off [A] -50.00 ± 5.00 (n=3)")
        XCTAssertEqual(value(r, "b"), "tgt [A] -185.00 ± 8.00 (n=3)   |   off needs-prep")
        XCTAssertEqual(value(r, "c"), "tgt [B] -100.00 ± 5.00 (n=3)   |   off failed")
        XCTAssertEqual(value(r, "a vs off"), "ratio 3.80 ± 0.42")
        XCTAssertEqual(r.scalar, -190.0)
        let cellRows = r.summary.filter { $0.label.contains("cell ") }
        XCTAssertEqual(cellRows.count, 3)                       // delivered cells of tgt only
        XCTAssertEqual(cellRows[0].label, "▸ cell 0: a")
        XCTAssertEqual(cellRows[0].value, "tier A, -190.00 ± 8.00")
    }

    func testNotesSayTiersNotRankOrderAndCountTheAbsentCells() throws {
        let dir = try tempDir("notes")
        let traj = try makeCampaign(dir, json: Self.full)
        let r = try CampaignMatrixTool.analyze(frame: frame(),
                                               context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                               params: .init())
        let notes = r.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("TIERS, NOT A RANK ORDER"), notes)
        XCTAssertTrue(notes.contains("2 tier(s)"), notes)
        XCTAssertTrue(notes.contains("cell index of column tgt"), notes)
        XCTAssertTrue(notes.contains("ABSENT, not zero"), notes)
        XCTAssertTrue(notes.contains("b__off, c__off"), notes)
        XCTAssertTrue(notes.contains("HIGH screen-rate-velocity"), notes)
        XCTAssertTrue(notes.contains("HIGH matrix-incomplete-grid"), notes)
        XCTAssertTrue(notes.contains("1 medium/low compromise(s): replicates-n3"), notes)
    }

    func testUnresolvedSelectivityIsNamedAsNoSelectivity() throws {
        let dir = try tempDir("unresolved")
        let traj = try makeCampaign(dir, json: Self.higher)
        let r = try CampaignMatrixTool.analyze(frame: frame(),
                                               context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                               params: .init())
        XCTAssertTrue(value(r, "a vs off")!.contains("band includes 1.00"), value(r, "a vs off")!)
        XCTAssertTrue(r.notes.joined().contains("shows no selectivity"), r.notes.joined())
        XCTAssertEqual(r.scalar, 12.0)                          // higher-is-stronger: a first
    }

    func testSortByValueHonoursDirectionAndByBandIsTheRerunQueue() throws {
        let m = try decode(Self.full)
        XCTAssertEqual(CampaignMatrixTool.sorted(m, receptor: "tgt", by: .tier).map(\.ligand), ["a", "b", "c"])
        XCTAssertEqual(CampaignMatrixTool.sorted(m, receptor: "tgt", by: .value).map(\.ligand), ["a", "b", "c"])
        XCTAssertEqual(CampaignMatrixTool.sorted(m, receptor: "tgt", by: .band).map(\.ligand), ["a", "b", "c"])
        let h = try decode(Self.higher)
        // higher is stronger here, so the LARGER tau sorts first
        XCTAssertEqual(CampaignMatrixTool.sorted(h, receptor: "tgt", by: .value).map(\.ligand), ["a", "b"])
        XCTAssertEqual(CampaignMatrixTool.sorted(h, receptor: "tgt", by: .band).map(\.ligand), ["a", "b"])
    }

    func testScrubbingPastTheColumnSaysWhatToDo() throws {
        let dir = try tempDir("past")
        let traj = try makeCampaign(dir, json: Self.full)
        XCTAssertThrowsError(try CampaignMatrixTool.analyze(
            frame: frame(), context: AnalysisContext(frameIndex: 9, sourceURL: traj), params: .init())) { err in
            XCTAssertTrue("\(err)".contains("campaign.py prep"), "\(err)")
        }
    }

    func testAFreshCampaignRendersInsteadOfFailing() throws {
        let dir = try tempDir("fresh")
        let traj = try makeCampaign(dir, json: Self.empty)
        let r = try CampaignMatrixTool.analyze(frame: frame(),
                                               context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                               params: .init())
        XCTAssertEqual(value(r, "Coverage"), "0 of 1 cells (0%)")
        XCTAssertEqual(value(r, "a"), "tgt needs-prep")
        XCTAssertNil(r.scalar)                                  // nothing measured: no number, not a zero
        XCTAssertTrue(r.notes.joined().contains("ABSENT, not zero"))
        XCTAssertTrue(r.notes.joined().contains("no delivered cell yet"), r.notes.joined())
        XCTAssertTrue(r.notes.joined().contains("campaign.py prep fresh"), r.notes.joined())
    }

    func testMissingMatrixNamesTheSearchPathsAndTheProducer() throws {
        let dir = try tempDir("missing")
        let traj = dir.appendingPathComponent("trajectory.xyz")
        try "1\nframe 0\nC 0 0 0\n".write(to: traj, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CampaignMatrixTool.analyze(
            frame: frame(), context: AnalysisContext(frameIndex: 0, sourceURL: traj), params: .init()))
        let note = CampaignMatrixTool.searchNote(context: AnalysisContext(frameIndex: 0, sourceURL: traj),
                                                 params: .init())
        XCTAssertTrue(note.contains("matrix.json"), note)
        XCTAssertTrue(note.contains("campaign.py matrix"), note)
    }

    func testRegisteredAndReachable() throws {
        let r = ToolRegistry()
        r.registerBuiltIns()
        XCTAssertTrue(r.metadata.contains { $0.id == "campaign_matrix" })
        let meta = r.metadata.first { $0.id == "campaign_matrix" }!
        XCTAssertEqual(meta.title, "Campaign matrix (tiers)")
        XCTAssertTrue(meta.requirements.contains(.sideFile))
    }
}
