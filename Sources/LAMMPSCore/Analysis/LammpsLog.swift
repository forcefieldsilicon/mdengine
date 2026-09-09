//
//  LammpsLog.swift — the thermo table out of `log.lammps`.
//
//  Everything a run measures about itself as a whole — temperature, pressure,
//  energies, box lengths, any `compute`/`variable` the deck put in a
//  `thermo_style custom` line — is in the log and nowhere in the dump. A
//  stress–strain curve in particular exists ONLY here: per-atom stresses are
//  optional and expensive, the box pressure is free and always printed.
//
//  Shape of a log: prose, then a header line whose first token is `Step`, then
//  whitespace-separated numeric rows, then `Loop time of …`. One block per
//  `run`, so a multi-run deck (equilibrate, then deform) gives several blocks,
//  and the deck may change `thermo_style` between them. Warnings are printed
//  inline, mid-table, whenever LAMMPS feels like it — a warning must not end a
//  block, and neither must a blank line.
//

import Foundation

public struct LammpsLog: Equatable {

    /// One `run`'s thermo table.
    public struct Block: Equatable {
        public let columns: [String]
        public let rows: [[Double]]
        /// Nil when the run was still going when we read the log.
        public let loopTime_s: Double?

        public init(columns: [String], rows: [[Double]], loopTime_s: Double? = nil) {
            self.columns = columns
            self.rows = rows
            self.loopTime_s = loopTime_s
        }

        public func column(_ name: String) -> [Double]? {
            guard let i = columns.firstIndex(of: name) else { return nil }
            return rows.map { i < $0.count ? $0[i] : .nan }
        }
    }

    public let blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    public var rowCount: Int { blocks.reduce(0) { $0 + $1.rows.count } }
    public var isEmpty: Bool { rowCount == 0 }

    /// Column names present in EVERY block — the only ones whose concatenated
    /// series stay row-aligned with each other across a multi-run log.
    public var commonColumns: [String] {
        guard let first = blocks.first else { return [] }
        var names = first.columns
        for b in blocks.dropFirst() {
            let have = Set(b.columns)
            names = names.filter { have.contains($0) }
        }
        return names
    }

    /// Every column name seen anywhere, in first-seen order.
    public var allColumns: [String] {
        var seen = Set<String>(), out: [String] = []
        for b in blocks { for c in b.columns where seen.insert(c).inserted { out.append(c) } }
        return out
    }

    /// One series for `name`, concatenated over the blocks that carry it.
    /// Row-aligned with any other series drawn from `commonColumns`.
    public func column(_ name: String) -> [Double]? {
        var out: [Double] = []
        var found = false
        for b in blocks {
            guard let c = b.column(name) else { continue }
            found = true
            out += c
        }
        return found ? out : nil
    }

    /// Which block each concatenated row came from (for "run 2 of 3" labels).
    public var rowBlockIndex: [Int] {
        var out: [Int] = []
        for (i, b) in blocks.enumerated() { out += [Int](repeating: i, count: b.rows.count) }
        return out
    }

    // MARK: - Parsing

    /// Header-driven and forgiving. Anything that is not a header, a full
    /// numeric row of the right width, or `Loop time` is ignored — which is
    /// what makes it survive `WARNING:` lines, per-run prose and the truncated
    /// tail of a log that is still being written.
    public static func parse(_ text: String) -> LammpsLog {
        var blocks: [Block] = []
        var columns: [String] = []
        var rows: [[Double]] = []

        func flush(loopTime: Double? = nil) {
            if !columns.isEmpty && !rows.isEmpty {
                blocks.append(Block(columns: columns, rows: rows, loopTime_s: loopTime))
            }
            columns = []; rows = []
        }

        // "\r\n" is ONE Swift Character, so splitting on "\n" would leave a
        // trailing "\r" on every field of a Windows-written log (and a log
        // fetched from a pod through some shells is exactly that).
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first else { continue }

            if first == "Step" {
                flush()                                  // a new run's header ends the previous block
                columns = tokens
                continue
            }
            if line.hasPrefix("Loop time of") {
                flush(loopTime: Double(tokens.count > 3 ? tokens[3] : ""))
                continue
            }
            guard !columns.isEmpty else { continue }     // prose before the first header
            if line.hasPrefix("WARNING") || line.hasPrefix("ERROR") { continue }
            guard tokens.count == columns.count else { continue }
            var row = [Double]()
            row.reserveCapacity(tokens.count)
            for t in tokens {
                guard let v = Double(t), v.isFinite else { row = []; break }
                row.append(v)
            }
            if row.count == columns.count { rows.append(row) }
        }
        flush()
        return LammpsLog(blocks: blocks)
    }

    // MARK: - Loading (cached by path + mtime + size)

    private static let cache = FileCache<LammpsLog>()

    public static func load(_ url: URL) throws -> LammpsLog {
        try cache.value(for: url) { parse(try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The log for a trajectory: `log.lammps` beside it, in a `results*/`
    /// sibling, or in the run directory above — the same search
    /// `ForceCurve.locate` does, then any other `*.log` / `log.*` in those
    /// directories, newest first.
    public static func locate(near url: URL) -> URL? {
        let fm = FileManager.default
        let named = searchLocations(near: url).first { fm.fileExists(atPath: $0.path) }
        if let named { return named }
        for dir in searchDirectories(near: url) {
            let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            let logs = kids.filter {
                let name = $0.lastPathComponent
                return $0.pathExtension == "log" || name.hasPrefix("log.")
            }
            if let newest = logs.max(by: { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da == db ? a.lastPathComponent > b.lastPathComponent : da < db
            }) { return newest }
        }
        return nil
    }

    /// Exactly where `log.lammps` is looked for, in order — quoted back to the
    /// user when it is not there.
    public static func searchLocations(near url: URL) -> [URL] {
        searchDirectories(near: url).map { $0.appendingPathComponent("log.lammps") }
    }

    static func searchDirectories(near url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let looksLikeDir = fm.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue
                                                                               : url.hasDirectoryPath
        let dir = looksLikeDir ? url.standardizedFileURL : url.deletingLastPathComponent().standardizedFileURL
        var out = [dir]
        out += ForceCurve.resultsChildren(of: dir)
        if dir.lastPathComponent.hasPrefix("results") {
            let up = dir.deletingLastPathComponent()
            out.append(up)
            out += ForceCurve.resultsChildren(of: up)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }
}
