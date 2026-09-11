//
//  CampaignMatrix.swift — the side file a screening campaign leaves behind.
//
//  Schema "dsuite.matrix/1", written by delivery/module1/campaign.py matrix:
//  one cell per (ligand, receptor) pair with its median and IQR/2 band, the
//  per-column tier letters, the resolution floor the campaign achieved, the
//  selectivity ratios across each row, and the union of every contributing
//  cell's compromises.
//
//  Two properties of this file drive every decision below.
//
//  First, most cells are legitimately EMPTY. A campaign's normal state is a
//  handful of delivered cells and a queue of unprepared ones — 1 of 30 on the
//  first GnRHR panel — because system prep, not GPU time, is the bottleneck.
//  So `value` is optional everywhere and an absent cell carries a `state`
//  ("needs-prep", "prepared", "partial", "failed"). It is never a zero.
//
//  Second, the file carries its own SEMANTICS: `direction` says which way is a
//  stronger interaction, `label` and `unit` say what the number is. Nothing
//  here hardcodes "lower is stronger" — that would drift the first time the
//  producer adds a quantity, and the producer already knows the answer.
//

import Foundation

public struct CampaignMatrix: Codable, Equatable {

    /// One (ligand, receptor) cell. `value` is nil unless the cell delivered.
    public struct Cell: Codable, Equatable {
        public let cell: String
        public let ligand: String
        public let receptor: String
        /// needs-prep | prepared | partial | ok | failed
        public let state: String
        public let value: Double?
        public let uncertainty: Double?
        public let n: Int?
        public let n_attempted: Int?
        public let tier: String?
        public let unit: String?
        public let note: String?

        /// A cell that produced a number. The others are absent, not weak.
        public var delivered: Bool { value != nil }
    }

    public struct Resolution: Codable, Equatable {
        public let median_band: Double?
        public let min_resolvable_difference: Double?
        public let rule: String?
    }

    public struct Selectivity: Codable, Equatable {
        public let ligand: String
        public let vs: String
        /// ratio | difference
        public let mode: String
        public let value: Double?
        public let uncertainty: Double?
        /// Does the band exclude the null (1.0 for a ratio, 0.0 for a difference)?
        public let resolved: Bool?
        public let null: Double?
    }

    public struct Compromise: Codable, Equatable {
        public let id: String
        public let severity: String
        public let what: String?
        public let effect_on_results: String?
        public let to_complete: String?

        public var isSerious: Bool { severity == "invalidating" || severity == "high" }
    }

    public let schema: String?
    public let campaign: String?
    public let protocolName: String?
    public let quantity: String?
    public let label: String?
    /// "higher" or "lower" — which way is a stronger interaction.
    public let direction: String?
    public let unit: String?
    public let ligands: [String]
    public let receptors: [String]
    public let primary_receptor: String?
    public let n_cells: Int?
    public let n_delivered: Int?
    public let coverage: Double?
    public let resolution: Resolution?
    public let cells: [String: Cell]
    /// Per receptor, the delivered cells in the producer's own strongest-first order.
    public let columns: [String: [String]]
    public let selectivity: [String: Selectivity]
    public let compromises: [Compromise]
    public let ok: Bool?

    enum CodingKeys: String, CodingKey {
        case schema, campaign, quantity, label, direction, unit, ligands, receptors
        case primary_receptor, n_cells, n_delivered, coverage, resolution, cells, columns
        case selectivity, compromises, ok
        case protocolName = "protocol"
    }

    /// Missing collections decode as empty, not as a failure: a campaign with no
    /// delivered cell yet is exactly when someone opens the viewer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        campaign = try c.decodeIfPresent(String.self, forKey: .campaign)
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName)
        quantity = try c.decodeIfPresent(String.self, forKey: .quantity)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        ligands = try c.decodeIfPresent([String].self, forKey: .ligands) ?? []
        receptors = try c.decodeIfPresent([String].self, forKey: .receptors) ?? []
        primary_receptor = try c.decodeIfPresent(String.self, forKey: .primary_receptor)
        n_cells = try c.decodeIfPresent(Int.self, forKey: .n_cells)
        n_delivered = try c.decodeIfPresent(Int.self, forKey: .n_delivered)
        coverage = try c.decodeIfPresent(Double.self, forKey: .coverage)
        resolution = try c.decodeIfPresent(Resolution.self, forKey: .resolution)
        cells = try c.decodeIfPresent([String: Cell].self, forKey: .cells) ?? [:]
        columns = try c.decodeIfPresent([String: [String]].self, forKey: .columns) ?? [:]
        selectivity = try c.decodeIfPresent([String: Selectivity].self, forKey: .selectivity) ?? [:]
        compromises = try c.decodeIfPresent([Compromise].self, forKey: .compromises) ?? []
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
    }

    // MARK: - Reading the file's own semantics

    /// True when a LOWER value means a stronger interaction (an adhesion force
    /// measured as negative, a binding free energy). Read from the file.
    public var lowerIsStronger: Bool { direction == "lower" }

    public var displayUnit: String { unit ?? cells.values.compactMap(\.unit).first ?? "" }

    /// The column a customer reads first.
    public var primaryColumn: String? { primary_receptor ?? receptors.first }

    public func cell(_ ligand: String, _ receptor: String) -> Cell? {
        cells["\(ligand)__\(receptor)"] ?? cells.values.first { $0.ligand == ligand && $0.receptor == receptor }
    }

    /// Delivered cells of one receptor column, in the producer's order when it
    /// gave one (so the tier letters and this order can never disagree).
    public func column(_ receptor: String) -> [Cell] {
        if let ids = columns[receptor], !ids.isEmpty {
            return ids.compactMap { cells[$0] }
        }
        return cells.values.filter { $0.receptor == receptor && $0.delivered }
            .sorted { lowerIsStronger ? ($0.value! < $1.value!) : ($0.value! > $1.value!) }
    }

    /// Cells with no number, by state — the prep queue, and the honest denominator.
    public func undelivered(_ receptor: String? = nil) -> [Cell] {
        cells.values
            .filter { !$0.delivered && (receptor == nil || $0.receptor == receptor!) }
            .sorted { $0.cell < $1.cell }
    }

    public var tierCount: Int {
        guard let r = primaryColumn else { return 0 }
        return Set(column(r).compactMap(\.tier)).count
    }

    // MARK: - Loading (cached by path + mtime + size, like FEPResults)

    private static let cache = FileCache<CampaignMatrix>()

    public static func load(_ url: URL) throws -> CampaignMatrix {
        try cache.value(for: url) {
            try JSONDecoder().decode(CampaignMatrix.self, from: try Data(contentsOf: $0))
        }
    }

    /// `matrix.json` for an anchor: beside it, in a `results*/` sibling, or — when
    /// the anchor sits inside a campaign's `cells/` — up at the campaign root.
    public static func locate(near url: URL) -> URL? {
        searchLocations(near: url).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func searchLocations(near url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let looksLikeDir = fm.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue
                                                                               : url.hasDirectoryPath
        var dir = looksLikeDir ? url.standardizedFileURL
                               : url.deletingLastPathComponent().standardizedFileURL
        var out = [dir.appendingPathComponent("matrix.json")]
        out += ForceCurve.resultsChildren(of: dir).map { $0.appendingPathComponent("matrix.json") }
        // A seed dir lives at <campaign>/cells/<cell>-s<N>[/results]; walk up to the campaign root.
        for _ in 0..<3 {
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path || up.path == "/" { break }
            out.append(up.appendingPathComponent("matrix.json"))
            dir = up
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }
}
