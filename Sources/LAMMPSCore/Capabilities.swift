import Foundation

// Capability manifest + deck preflight for the hosted tier (GJOB-118, 2026-09-07).
// Mirror of hosted/endpoint/mde_caps.py — same categories, same rules, same wording. A style is
// GPU-accelerated on the KOKKOS/CUDA runner exactly when LAMMPS lists its `/kk` variant; anything
// else still runs, on the pod's CPU cores at the GPU rate — which is what a paying user must hear
// BEFORE the launch, not after the bill.

public struct HostedStyleInfo: Codable, Equatable {
    public let gpu: Bool
    public let variants: [String]?
    public init(gpu: Bool, variants: [String]? = nil) { self.gpu = gpu; self.variants = variants }
}

/// One runner flavour's manifest (`runners.lammps` in GET /v1/capabilities). Fields optional so the
/// OpenMM flavour's smaller record decodes too.
public struct HostedRunnerCapabilities: Codable {
    public let engine: String?
    public let lammps_version: String?
    public let image: String?
    public let accelerator: String?
    public let packages: [String]?
    public let styles: [String: [String: HostedStyleInfo]]?
    public init(engine: String? = "lammps", lammps_version: String? = nil, image: String? = nil, accelerator: String? = nil,
                packages: [String]? = nil, styles: [String: [String: HostedStyleInfo]]? = nil) {
        self.engine = engine; self.lammps_version = lammps_version; self.image = image; self.accelerator = accelerator
        self.packages = packages; self.styles = styles
    }
}

/// `routing` in GET /v1/capabilities (GJOB-116): the default image and the fuller ones a deck may be sent to.
public struct HostedRouting: Codable {
    public let defaultRunner: String?
    public let fallbacks: [String]?
    enum CodingKeys: String, CodingKey { case defaultRunner = "default", fallbacks }
    public init(defaultRunner: String? = "lammps", fallbacks: [String]? = nil) { self.defaultRunner = defaultRunner; self.fallbacks = fallbacks }
}

public struct HostedCapabilities: Codable {
    public let runners: [String: HostedRunnerCapabilities]
    public let default_runner: String?
    public let rates: [String: Double]?
    public let routing: HostedRouting?
    /// Packages on no hosted image by decision (KIM), with the sentence to show.
    public let excluded_packages: [String: String]?
    /// How jobs are priced (GJOB-129); nil from an endpoint older than the flip.
    public let pricing: HostedPricing?
    public var defaultRunner: String { default_runner ?? "lammps" }
    public var lammps: HostedRunnerCapabilities? { runners[defaultRunner] ?? runners["lammps"] }
    public init(runners: [String: HostedRunnerCapabilities], default_runner: String? = "lammps", rates: [String: Double]? = nil,
                routing: HostedRouting? = nil, excluded_packages: [String: String]? = nil, pricing: HostedPricing? = nil) {
        self.runners = runners; self.default_runner = default_runner; self.rates = rates; self.routing = routing; self.excluded_packages = excluded_packages
        self.pricing = pricing
    }
}

/// Per-process cache of the manifest (10 min): the app polls, the MCP server lives for a session.
final class CapabilitiesCache: @unchecked Sendable {
    static let shared = CapabilitiesCache()
    private let lock = NSLock()
    private var entry: (Date, URL, HostedCapabilities)?
    func get(_ base: URL) -> HostedCapabilities? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entry, e.1 == base, Date().timeIntervalSince(e.0) < 600 else { return nil }
        return e.2
    }
    func put(_ base: URL, _ caps: HostedCapabilities) { lock.lock(); entry = (Date(), base, caps); lock.unlock() }
}

extension HostedClient {
    /// GET /v1/capabilities (keyless on the server; we send the key anyway).
    public func capabilities() throws -> HostedCapabilities {
        if let c = CapabilitiesCache.shared.get(base) { return c }
        let caps = try decode(HostedCapabilities.self, request("GET", "capabilities"), expect: [200])
        CapabilitiesCache.shared.put(base, caps)
        return caps
    }
}

/// What a deck asks for versus what the runner has.
public struct DeckPreflight {
    public struct Finding: Equatable {
        public let command: String, style: String, file: String, line: Int
        public var why: String?
    }
    public var input: String
    public var missing: [Finding] = []
    public var cpuOnly: [Finding] = []
    public var gpu: [Finding] = []
    public var notes: [String] = []
    /// true = every pair style is KOKKOS-accelerated; false = at least one is not; nil = no pair_style seen.
    public var usesGPU: Bool?
    /// Set by `route`: the fuller runner this deck will run on, and the default-image styles that forced it.
    public var routedTo: String?
    public var routedBecause: [String] = []
    /// Set by `route` when no image satisfies the deck: every runner checked, for the wording.
    public var tried: [String] = []
    /// Style base -> the server's sentence for its excluded package (from `excluded_packages`; today only "kim").
    public var excluded: [String: String] = [:]
    /// Mirror of mde_caps.launch_line() (GJOB-126): which launch line the endpoint will pick for this deck.
    /// `.plain` means no accelerator at all — plain `lmp` on the pod's CPU cores, at the same hourly rate.
    public var launchMode: LaunchMode = .kokkos
    public var launchBecause: [LaunchBlock] = []
    public var ok: Bool { missing.isEmpty }
    /// Something a client must show before spending: a missing style or a CPU-only pair style.
    public var needsAttention: Bool { !missing.isEmpty || usesGPU == false }

    public enum LaunchMode: String, Equatable { case kokkos, plain }
    public struct LaunchBlock: Equatable {
        public let what: String, why: String, file: String
        public let line: Int
    }
    /// Fix styles the default `-sf kk` line cannot run, with LAMMPS' own reason. Every entry is one family
    /// measured failing at startup in parity run MDJOB-20260907-FC62CB; keep in step with mde_caps.KK_BLOCKED_FIXES.
    static let blockedFixes: [String: String] = [
        "pour": "fix pour cannot yet be used with the KOKKOS package",
        "shardlow": "fix shardlow/kk requires pair_style dpd/fdt/energy/kk",
        "gcmc": "fix gcmc leaves a fix-in-variable uncomputed at a compatible time under KOKKOS",
        "srd": "fix srd requests a neighbor list KOKKOS cannot build (it supports only 'bin' lists)"]

    static let accel: Set<String> = ["kk", "omp", "opt", "gpu", "intel"]
    static let hybrid: Set<String> = ["hybrid", "hybrid/overlay", "hybrid/scaled", "hybrid/molecular"]
    static let commands: [String: (String, Int)] = [
        "pair_style": ("pair", 1), "bond_style": ("bond", 1), "angle_style": ("angle", 1), "dihedral_style": ("dihedral", 1),
        "improper_style": ("improper", 1), "kspace_style": ("kspace", 1), "atom_style": ("atom", 1), "min_style": ("minimize", 1),
        "run_style": ("integrate", 1), "fix": ("fix", 3), "compute": ("compute", 3), "dump": ("dump", 3), "region": ("region", 2)]

    static func splitAccel(_ name: String) -> (String, String?) {
        guard let i = name.lastIndex(of: "/") else { return (name, nil) }
        let tail = String(name[name.index(after: i)...]), head = String(name[..<i])
        return (!head.isEmpty && accel.contains(tail)) ? (head, tail) : (name, nil)
    }

    /// Join `&` continuations, drop `#` comments → (first line number, tokens).
    static func logicalLines(_ text: String) -> [(Int, [String])] {
        var out: [(Int, [String])] = [], buf: [String] = [], start: Int? = nil
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            var line = String(raw)
            if let h = line.firstIndex(of: "#") { line = String(line[..<h]) }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if start == nil { start = i + 1 }
            if line.hasSuffix("&") { buf.append(String(line.dropLast())); continue }
            buf.append(line)
            let toks = buf.joined(separator: " ").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let s = start!; buf = []; start = nil
            if !toks.isEmpty { out.append((s, toks)) }
        }
        return out
    }

    /// Check the deck at `input` (its directory is the deck) against a runner manifest. Never throws on deck content.
    /// Does a LAMMPS data file declare type labels? Those become a label map, which Kokkos does not support.
    /// Same 4 MB ceiling the endpoint's tarball reader uses, so both sides see the same files.
    static func declaresTypeLabels(_ url: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path), data.count < 4_000_000 else { return false }
        let text = String(decoding: data, as: UTF8.self)
        let headers: Set<String> = ["Atom Type Labels", "Bond Type Labels", "Angle Type Labels",
                                    "Dihedral Type Labels", "Improper Type Labels"]
        // Line by line, not one anchored regex: `range(of:options:.regularExpression)` cannot ask for
        // anchorsMatchLines, so `^`/`$` would only ever match the whole file's ends.
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                   .contains { headers.contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    public static func check(input: URL, caps: HostedRunnerCapabilities?) -> DeckPreflight {
        var rep = DeckPreflight(input: input.lastPathComponent)
        let deckDir = input.deletingLastPathComponent().standardizedFileURL
        guard let styles = caps?.styles, !styles.isEmpty else {
            rep.notes.append("no capability manifest available; nothing checked"); return rep
        }
        var pairFlags: [Bool] = []
        var seen: Set<String> = []
        let atom = styles["atom"] ?? [:], fixes = styles["fix"] ?? [:]
        var fixStyle: [String: String] = [:]                      // fix id -> base style, for fix_modify
        var pendingModify: [(id: String, file: String, line: Int)] = []
        func block(_ what: String, _ why: String, _ file: String, _ line: Int) {
            rep.launchBecause.append(LaunchBlock(what: what, why: why, file: file, line: line))
        }
        func launchRules(_ cmd: String, _ toks: [String], _ rel: String, _ ln: Int) {
            switch cmd {
            case "atom_style" where toks.count > 1 && !toks[1].contains("$"):
                let base = splitAccel(toks[1]).0
                if hybrid.contains(base) {
                    block("atom_style \(base)", "AtomVecHybridKokkos does not support threaded comm", rel, ln)
                } else if !atom.isEmpty, !(atom[base]?.gpu ?? false) {
                    block("atom_style \(base)", "KOKKOS requires a Kokkos-enabled atom_style and this one has no /kk variant", rel, ln)
                }
            case "bond_style" where toks.count > 1 && hybrid.contains(splitAccel(toks[1]).0):
                block("bond_style hybrid", "bond_style hybrid/kk accepts only Kokkos-enabled sub-styles", rel, ln)
            case "fix" where toks.count > 3:
                let base = splitAccel(toks[3]).0
                fixStyle[toks[1]] = base
                if let why = blockedFixes[base] { block("fix \(base)", why, rel, ln) }
            case "compute" where toks.count > 3 && splitAccel(toks[3]).0.hasSuffix("/tally"):
                block("compute \(toks[3])", "compute styles ending in /tally cannot yet be used with KOKKOS", rel, ln)
            case "labelmap":
                block("labelmap", "label maps are not supported with Kokkos", rel, ln)
            case "read_data" where toks.count > 1 && !toks[1].contains("$"):
                if declaresTypeLabels(deckDir.appendingPathComponent(toks[1]).standardizedFileURL) {
                    block("read_data \(toks[1])", "the data file declares type labels, and label maps are not supported with Kokkos", rel, ln)
                }
            case "fix_modify" where toks.count > 2 && toks.dropFirst(2).contains("energy"):
                pendingModify.append((toks[1], rel, ln))          // resolved after the walk: the fix may come later
            default: break
            }
        }

        func walk(_ file: URL, depth: Int) {
            let rel = file.lastPathComponent
            guard depth <= 5, !seen.contains(file.path) else { return }
            seen.insert(file.path)
            guard let data = FileManager.default.contents(atPath: file.path), data.count < 4_000_000,
                  !data.prefix(4096).contains(0) else {
                rep.notes.append("include \(rel): file not in deck (not checked)"); return
            }
            let text = String(decoding: data, as: UTF8.self)
            for (ln, toks) in logicalLines(text) {
                let cmd = toks[0]
                if cmd == "include", toks.count > 1, !toks[1].contains("$") {
                    walk(file.deletingLastPathComponent().appendingPathComponent(toks[1]).standardizedFileURL, depth: depth + 1); continue
                }
                launchRules(cmd, toks, rel, ln)
                guard let (cat, idx) = commands[cmd], toks.count > idx else { continue }
                let style = toks[idx]
                if style.contains("$") || style == "none" { continue }
                let table = styles[cat] ?? [:]
                func classify(_ s: String, sub: Bool) {
                    let (base, acc) = splitAccel(s)
                    let f = Finding(command: cmd, style: s, file: rel, line: ln)
                    guard let e = table[base] else { if !sub { rep.missing.append(f) }; return }
                    if let acc, acc != "kk", !(e.variants ?? []).contains(acc) {
                        var m = f; m.why = "no /\(acc) variant"; rep.missing.append(m); return
                    }
                    if e.gpu { rep.gpu.append(f) } else { rep.cpuOnly.append(f) }
                    if cat == "pair", !hybrid.contains(base) { pairFlags.append(e.gpu) }
                }
                classify(style, sub: false)
                if hybrid.contains(splitAccel(style).0) {
                    for t in toks[(idx + 1)...] where !t.contains("$") && t.range(of: "^[a-z][a-z0-9_./+-]*$", options: .regularExpression) != nil {
                        classify(t, sub: true)
                    }
                }
            }
        }
        walk(input.standardizedFileURL, depth: 0)
        for m in pendingModify {                                  // only a fix that HAS a /kk variant can break on this
            guard let st = fixStyle[m.id], fixes[st]?.gpu == true else { continue }
            block("fix_modify \(m.id) energy", "fix \(st)/kk does not support fix_modify energy", m.file, m.line)
        }
        if !pairFlags.isEmpty { rep.usesGPU = pairFlags.allSatisfy { $0 } }
        if !rep.launchBecause.isEmpty { rep.launchMode = .plain; rep.usesGPU = false }
        return rep
    }

    /// Mirror of mde_caps.route(): the cheapest runner whose manifest satisfies the deck. `runner` is nil when the
    /// default image suffices (or nothing does — then `missing` is non-empty and `tried` lists every image checked),
    /// otherwise the fallback the endpoint will also pick at start; pass it as the job's `runner` so the CLI's promise
    /// and the server's decision are the same thing.
    public static func route(input: URL, caps: HostedCapabilities?) -> (runner: String?, report: DeckPreflight) {
        let dflt = caps?.defaultRunner ?? "lammps"
        var rep = check(input: input, caps: caps?.lammps)
        rep.excluded = excludedStyles(caps)
        if rep.missing.isEmpty { return (nil, rep) }
        var tried = [dflt]
        for fb in caps?.routing?.fallbacks ?? [] where fb != dflt {
            guard let man = caps?.runners[fb], let st = man.styles, !st.isEmpty else { continue }
            tried.append(fb)
            var r2 = check(input: input, caps: man)
            if r2.missing.isEmpty {
                r2.routedTo = fb; r2.routedBecause = Array(Set(rep.missing.map(\.style))).sorted(); r2.excluded = rep.excluded
                return (fb, r2)
            }
        }
        rep.tried = tried
        return (nil, rep)
    }

    /// Style base -> the server's sentence for its excluded package. Only KIM (pair_style kim) is known today.
    static func excludedStyles(_ caps: HostedCapabilities?) -> [String: String] {
        guard let sentence = caps?.excluded_packages?["KIM"] else { return [:] }
        return ["kim": sentence]
    }

    /// The same sentences mde_caps.summarize() prints. Empty = nothing to say.
    public func lines(rateHint: String? = nil) -> [String] {
        var out: [String] = []
        if let to = routedTo {
            out.append("Routed to the full LAMMPS image (\(to)): \(routedBecause.joined(separator: ", ")) not in the fast default image. Same rate; the launch takes ~40 s longer for the bigger pull.")
        }
        if launchMode == .plain {
            let why = launchBecause.prefix(3).map { "\($0.what) (\($0.file):\($0.line)) \($0.why)" }.joined(separator: "; ")
            let more = launchBecause.count > 3 ? " (+\(launchBecause.count - 3) more)" : ""
            out.append("This deck runs WITHOUT the GPU accelerator: plain lmp on the pod's CPU cores, because \(why)\(more). "
                       + "Under the default -sf kk line LAMMPS exits at startup, so we launch the line it can run — the hourly rate is unchanged"
                       + "\(rateHint.map { " (\($0))" } ?? "") and the free local tier is likely as fast.")
        }
        let whereMissing = tried.count > 1 ? "not built into any hosted LAMMPS image (checked: \(tried.joined(separator: ", ")))" : "not built into the hosted LAMMPS image"
        for m in missing {
            var why = m.why ?? whereMissing
            if m.why == nil, let sentence = excluded[DeckPreflight.splitAccel(m.style).0] { why += "; \(sentence)" }
            out.append("\(m.command) \(m.style) (\(m.file):\(m.line)) — \(why); LAMMPS would exit at startup. Run it on the free local tier or ask us to add the package.")
        }
        if usesGPU == false, launchMode != .plain {
            let pairs = Set(cpuOnly.filter { $0.command == "pair_style" }.map(\.style)).sorted().joined(separator: ", ")
            out.append("This deck will NOT use the GPU: pair_style \(pairs) has no KOKKOS (/kk) version, so the pair force runs on the pod's CPU cores at the GPU rate\(rateHint.map { " (\($0))" } ?? ""). The free local run is likely as fast.")
        }
        let other = Set(cpuOnly.filter { $0.command != "pair_style" }.map { "\($0.command) \($0.style)" }).sorted()
        if !other.isEmpty, usesGPU != false {
            out.append("CPU-side styles (normal, small cost): " + other.prefix(8).joined(separator: ", ") + (other.count > 8 ? " …" : ""))
        }
        return out + notes
    }
}
