//
//  mdengine — command-line companion to MDEngine.app.
//  Inspect, decimate, and export XYZ trajectories; run LAMMPS with the
//  OpenMP acceleration flags set correctly for this machine.
//

import Foundation
import LAMMPSCore

let usage = """
mdengine — MD trajectory tool (CLI companion to MDEngine.app)

USAGE
  mdengine info <file> [--elements A,B,..] frames, atoms, fields, elements, bbox
  mdengine export <file> [-o out.xyz] [--frame last|first|N]
                         [--charges] [--elements A,B,..]
                                           write one frame as XYZ (--charges:
                                           extended-XYZ with per-atom q column)
  mdengine analyze                         list the analysis tools (id, category,
                                           what they produce, default parameters)
  mdengine analyze <tool> <file> [--frame last|first|N]
                                 [--all | --frames a-b[:stride]]
                                 [--param k=v ...] [--params '<json>']
                                 [--csv out.csv] [--json]
                                           run one analysis tool on a frame:
                                           summary table + profile + notes
                                           (--all/--frames = scalar per frame)
  mdengine decimate <file> --every N [-o out.xyz] [--charges]
                                           keep every Nth frame (last always kept)
  mdengine run <input> [--threads N] [--lmp PATH] [--log FILE]
                                           run LAMMPS with -sf omp -pk omp N
  mdengine run --gpu <input> [--label S] [--gpu-type any|rtx4090|a100]
                             [--runner lammps|openmm] [--launch "python3 {input}"]
                             [--wall-hours H] [--estimate-min M] [--no-wait] [--force]
                                           run on a hosted GPU (prepaid credits):
                                           ships the deck's directory, streams
                                           thermo, downloads results when done
  mdengine login <mde_key> [--endpoint URL]  store the API key (~/.mdengine/credentials)
  mdengine account                         credit balance + rate table
  mdengine capabilities [<deck.in>]        what the hosted runner can do; with a deck:
                                           preflight (missing styles, GPU vs CPU-only)
  mdengine jobs                            hosted jobs, newest first
  mdengine job <id> [--log|--fetch|--cancel|--wait]
                                           status / thermo tail / download / cancel
  mdengine gui                             open MDEngine.app

NOTES
  Trajectories are XYZ / extended-XYZ or native LAMMPS dump (ITEM: TIMESTEP).
  --elements maps numeric type tokens to symbols by position: --elements O,Al
  labels type 1 as O and type 2 as Al.
  Rows with non-finite (NaN/inf) coordinates are dropped. Safe on in-flight
  dumps: a file still being written parses to its complete frames.
  Every subcommand accepts -h/--help.
  `analyze` runs the same tools as the app's inspector and the MCP `analyze`
  tool; --param values are typed (int, float, true/false, else string) and a
  value the tool cannot decode falls back to that tool's default.
  `run` finds LAMMPS via $MDENGINE_LMP, then lmp_mpi / lmp_serial / lmp on PATH.
  Default --threads = number of performance cores.
  --gpu needs an API key (comes with a credit pack: forcefieldsilicon.com/mdengine);
  $MDENGINE_API_KEY / $MDENGINE_HOSTED_URL override the stored credentials.
  A hosted deck must be self-contained in its directory (data, potentials, molecule files).
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func readFrames(_ path: String) -> [[Arv]] {
    if let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
       bytes > 2_000_000_000 {
        fail("\(path) is \(bytes / 1_000_000) MB — mdengine loads whole trajectories "
           + "into memory (limit 2 GB). Decimate or split the file first.")
    }
    guard let frames = try? TrajectoryReader.parseFrames(contentsOf: URL(fileURLWithPath: path)) else {
        fail("cannot read \(path)")
    }
    return frames
}

func readTrajectory(_ path: String) -> String {
    // Trajectories are loaded whole; refuse sizes that would thrash the machine.
    if let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
       bytes > 2_000_000_000 {
        fail("\(path) is \(bytes / 1_000_000) MB — mdengine loads whole trajectories "
           + "into memory (limit 2 GB). Decimate or split the file first.")
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    return text
}

/// True if `flag` present in args, removing it.
func takeFlag(_ flag: String, _ args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

/// Map numeric type tokens to element symbols per `--elements A,B,...` (1-based).
func applyElementMap(_ frames: [[Arv]], _ args: inout [String]) -> [[Arv]] {
    guard let spec = takeOption("--elements", &args) else { return frames }
    let symbols = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    return frames.mappingElements(symbols)
}

/// Value of `--flag v` in args, removing both tokens.
func takeOption(_ flag: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func performanceCores() -> Int {
    var n: Int32 = 0
    var len = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.physicalcpu", &n, &len, nil, 0) == 0, n > 0 {
        return Int(n)
    }
    return max(1, ProcessInfo.processInfo.processorCount / 2)
}

func findLAMMPS() -> String? {
    if let env = ProcessInfo.processInfo.environment["MDENGINE_LMP"],
       FileManager.default.isExecutableFile(atPath: env) {
        return env
    }
    // Always probe the standard install dirs too: GUI-launched processes
    // get a minimal PATH without Homebrew.
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin"
    for name in ["lmp_mpi", "lmp_serial", "lmp"] {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
    }
    return nil
}

/// LAMMPS looks up bare force-field names (e.g. ffield.reax.Fe_O_C_H) in
/// $LAMMPS_POTENTIALS. If the user hasn't set it, derive it from the LAMMPS
/// install so bundled decks work out of the box.
func potentialsDir(for lmp: String) -> String? {
    if ProcessInfo.processInfo.environment["LAMMPS_POTENTIALS"] != nil { return nil }
    let real = URL(fileURLWithPath: lmp).resolvingSymlinksInPath()
    let candidates = [
        real.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/lammps/potentials").path,
        "/opt/homebrew/share/lammps/potentials",
        "/usr/local/share/lammps/potentials",
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
}

func shellQuoteCLI(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Stream state changes + new thermo lines until terminal, then download results. Returns the exit code to use.
func hostedWaitAndFetch(_ client: HostedClient, _ id: String) -> Int32 {
    do {
        let final = try client.wait(id, every: 5) { s, fresh in
            for line in fresh { print("  " + line) }
            if fresh.isEmpty, !s.isTerminal { print("mdengine: \(s.summary)") }
            fflush(stdout)   // after the state line: keep `mdengine run --gpu > log &` readable
        }
        print("mdengine: \(final.summary)")
        fflush(stdout)       // the fetch below can take minutes on a large results tarball
        guard final.state == "done" || final.state == "failed" else { return 1 }
        let dir = try client.fetch(id)
        print("results → \(dir.path)")
        if let t = HostedClient.primaryTrajectory(in: dir) { print("trajectory: \(t.path)") }
        return final.state == "done" ? 0 : Int32(final.exitcode ?? 1)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}

// MARK: - `analyze` helpers (the LAMMPSCore tool registry, from the shell)

/// Full parse (atoms + box + per-atom columns) — analysis tools need more than
/// `readFrames`' bare atom lists.
/// Side-file tools (fep_results, kinetics_tramd, pulloff_energetics, thermo) do not need atoms:
/// a run directory, a .json or a .csv is accepted and stands in as a one-frame anchor whose
/// `sourceURL` the tool searches from. Everything else is parsed as a trajectory.
func isSideFileAnchor(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return true }
    return ["json", "csv", "lammps", "log"].contains((path as NSString).pathExtension.lowercased())
}

func readTrajectoryFrames(_ path: String) -> Trajectory {
    if isSideFileAnchor(path) { return [Frame(atoms: [])] }
    if let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
       bytes > 2_000_000_000 {
        fail("\(path) is \(bytes / 1_000_000) MB — mdengine loads whole trajectories "
           + "into memory (limit 2 GB). Decimate or split the file first.")
    }
    guard let frames = try? TrajectoryReader.parseTrajectory(contentsOf: URL(fileURLWithPath: path)),
          !frames.isEmpty else {
        fail("no complete frames found in \(path)")
    }
    return frames
}

/// Rows padded to a common width per column (last column unpadded).
func printAligned(_ rows: [[String]], indent: String = "") {
    guard let columns = rows.map(\.count).max() else { return }
    var widths = [Int](repeating: 0, count: columns)
    for row in rows {
        for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
    }
    for row in rows {
        var line = indent
        for (i, cell) in row.enumerated() {
            line += i == row.count - 1 ? cell
                                       : cell.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0)
        }
        while line.hasSuffix(" ") { line.removeLast() }   // no trailing padding (empty units)
        print(line)
    }
}

func printToolCatalogue() {
    print("registered analysis tools — `mdengine analyze <id> <file>`\n")
    var rows: [[String]] = [["ID", "CATEGORY", "FUNCTIONS", "DEFAULT PARAMETERS"]]
    for m in ToolRegistry.shared.metadata {
        let defaults = ToolRegistry.shared.tool(m.id)?.defaultParametersJSON ?? Data()
        let params = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any] ?? [:]
        let flat = params.keys.sorted().map { key -> String in
            let v = params[key]!
            if let dict = v as? [String: Any] {
                return "\(key)=\(dict["kind"] as? String ?? "{…}")"
            }
            return "\(key)=\(v)"
        }.joined(separator: " ")
        rows.append([m.id, m.category.title, m.functions.map(\.rawValue).joined(separator: "+"),
                     flat.isEmpty ? "—" : flat])
    }
    printAligned(rows)
    print("\nOverride any of them with --param key=value or --params '{\"key\":value}'.")
}

/// "1" → Int, "1.5" → Double, "true" → Bool, anything else → String.
func typedParameterValue(_ raw: String) -> Any {
    if let i = Int(raw) { return i }
    if let d = Double(raw) { return d }
    if let b = Bool(raw) { return b }
    return raw
}

/// Caller parameters layered over the tool's defaults.
func mergedParameters(toolId: String, overrides: [String: Any]) -> Data {
    guard let tool = ToolRegistry.shared.tool(toolId) else {
        fail("unknown tool '\(toolId)' — registered: "
           + ToolRegistry.shared.metadata.map(\.id).joined(separator: ", "))
    }
    var merged = (try? JSONSerialization.jsonObject(with: tool.defaultParametersJSON))
        as? [String: Any] ?? [:]
    for (key, value) in overrides { merged[key] = value }
    return (try? JSONSerialization.data(withJSONObject: merged)) ?? tool.defaultParametersJSON
}

func frameIndex(_ spec: String, count: Int) -> Int {
    switch spec {
    case "last", "": return count - 1
    case "first": return 0
    default:
        guard let i = Int(spec), (0..<count).contains(i) else {
            fail("--frame must be 'first', 'last', or 0…\(count - 1)")
        }
        return i
    }
}

/// "all" | "a-b" | "a-b:stride" → the frame indices to walk.
func frameRange(_ spec: String, count: Int) -> [Int] {
    if spec == "all" { return Array(0..<count) }
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
    let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count <= 2, bounds.count == 2,
          let lo = Int(bounds[0]), let hi = Int(bounds[1]),
          let step = parts.count == 2 ? Int(parts[1]) : 1,
          step >= 1, lo >= 0, hi < count, lo <= hi else {
        fail("--frames must be 'all', 'a-b' or 'a-b:stride' within 0…\(count - 1)")
    }
    return Array(stride(from: lo, through: hi, by: step))
}

func csvField(_ s: String) -> String {
    s.contains(",") || s.contains("\"") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
}

func prettyJSONString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

/// ToolResult as a JSON object; per-atom values are dropped (megabytes of text).
func resultObject(_ result: ToolResult) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(result),
          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    if var field = obj["field"] as? [String: Any] {
        field["count"] = (field["values"] as? [Any])?.count ?? 0
        field.removeValue(forKey: "values")
        obj["field"] = field
    }
    return obj
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

// `mdengine <cmd> -h/--help` prints usage instead of treating the flag as a file.
if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

switch command {

case "info":
    guard let path = args.first else { fail("usage: mdengine info <file> [--elements A,B,..]") }
    args.removeFirst()
    var frames = readFrames(path)
    guard !frames.isEmpty else { fail("no complete frames found in \(path)") }
    frames = applyElementMap(frames, &args)
    print("file:    \(path)")
    print("frames:  \(frames.count)")
    // Only the head is needed for the fields line — not a whole-file String.
    let head: String = (try? FileHandle(forReadingAtPath: path)
        .map { String(decoding: $0.readData(ofLength: 65536), as: UTF8.self) }) ?? ""
    if let fields = TrajectoryReader.dumpFields(head) {
        print("fields:  \(fields.joined(separator: " "))")
    }
    let counts = frames.map(\.count)
    if Set(counts).count == 1 {
        print("atoms:   \(counts[0]) per frame")
    } else {
        print("atoms:   varies \(counts.min()!)–\(counts.max()!) (first \(counts.first!), last \(counts.last!))")
    }
    let last = frames.last!
    var histogram: [String: Int] = [:]
    for a in last { histogram[a.element, default: 0] += 1 }
    let elements = histogram.sorted { $0.value > $1.value }
        .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    print("last frame elements: \(elements)")
    let xs = last.map(\.x), ys = last.map(\.y), zs = last.map(\.z)
    func span(_ v: [Double]) -> String {
        String(format: "%.2f…%.2f", v.min()!, v.max()!)
    }
    print("bbox (Å): x \(span(xs)) | y \(span(ys)) | z \(span(zs))")
    if last.contains(where: { $0.charge != nil }) {
        let qs = last.compactMap(\.charge)
        print("charges: present (q \(span(qs)))")
    }

case "export":
    guard let path = args.first else { fail("usage: mdengine export <file> [-o out] [--frame N]") }
    args.removeFirst()
    let out = takeOption("-o", &args) ?? "frame.xyz"
    let which = takeOption("--frame", &args) ?? "last"
    let charges = takeFlag("--charges", &args)
    var frames = readFrames(path)
    guard !frames.isEmpty else { fail("no complete frames found in \(path)") }
    frames = applyElementMap(frames, &args)
    let frame: [Arv]
    switch which {
    case "last": frame = frames.last!
    case "first": frame = frames.first!
    default:
        guard let n = Int(which), frames.indices.contains(n) else {
            fail("--frame must be 'first', 'last', or 0…\(frames.count - 1)")
        }
        frame = frames[n]
    }
    do {
        try TrajectoryWriter.xyz([frame], comment: "Exported from mdengine — \(path) frame \(which)", charges: charges)
            .write(toFile: out, atomically: true, encoding: .utf8)
        print("wrote \(frame.count) atoms → \(out)\(charges ? " (extended-XYZ with charges)" : "")")
    } catch { fail("write failed: \(error.localizedDescription)") }

case "analyze":
    let wantJSON = takeFlag("--json", &args)
    let all = takeFlag("--all", &args)
    let csvOut = takeOption("--csv", &args)
    let framesSpec = takeOption("--frames", &args) ?? (all ? "all" : nil)
    let frameSpec = takeOption("--frame", &args) ?? "last"
    let referenceIndex = Int(takeOption("--reference", &args) ?? "0") ?? 0   // tools with a reference frame
    let paramsJSONText = takeOption("--params", &args)
    var overrides: [String: Any] = [:]
    if let text = paramsJSONText {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("--params must be a JSON object, e.g. '{\"bins\":32}'")
        }
        overrides = obj
    }
    while let pair = takeOption("--param", &args) {
        guard let eq = pair.firstIndex(of: "=") else { fail("--param takes key=value (got '\(pair)')") }
        overrides[String(pair[pair.startIndex..<eq])] = typedParameterValue(String(pair[pair.index(after: eq)...]))
    }
    let positional = args.filter { !$0.hasPrefix("--") }
    guard positional.count >= 2 else { printToolCatalogue(); break }

    let toolId = positional[0], path = positional[1]
    guard let tool = ToolRegistry.shared.tool(toolId) else {
        fail("unknown tool '\(toolId)' — registered: "
           + ToolRegistry.shared.metadata.map(\.id).joined(separator: ", "))
    }
    let title = ToolRegistry.shared.metadata.first { $0.id == toolId }?.title ?? toolId
    var trajectory = readTrajectoryFrames(path)
    if isSideFileAnchor(path) {
        // The side file IS the input: hand it to the tool explicitly and let --frame N mean
        // "row / edge N" by giving the anchor N+1 empty frames.
        let key = ["fep_results": "jsonPath", "kinetics_tramd": "csvPath",
                   "pulloff_energetics": "csvPath", "thermo": "logPath"][toolId]
        if let key, !(path as NSString).pathExtension.isEmpty, overrides[key] == nil { overrides[key] = path }
        if framesSpec != nil { fail("with a side file as input, use --frame N (row/edge index), or pass the trajectory for --all") }
        if let n = Int(frameSpec), n > 0 { trajectory = Array(repeating: Frame(atoms: []), count: n + 1) }
    }
    let paramsData = mergedParameters(toolId: toolId, overrides: overrides)
    let indices = framesSpec.map { frameRange($0, count: trajectory.count) }
        ?? [frameIndex(frameSpec, count: trajectory.count)]

    var results: [(frame: Int, result: ToolResult)] = []
    for i in indices {
        do {
            let ref = referenceIndex, hasRef = trajectory.indices.contains(ref)
            let source = URL(fileURLWithPath: path)
            let ctx = hasRef ? AnalysisContext(frameIndex: i, referenceFrame: trajectory[ref], referenceFrameIndex: ref,
                                               sourceURL: source, trajectory: trajectory, trajectoryGeneration: 1)
                             : AnalysisContext(frameIndex: i, sourceURL: source, trajectory: trajectory, trajectoryGeneration: 1)
            results.append((i, try tool.analyze(frame: trajectory[i], context: ctx, parametersJSON: paramsData)))
        } catch { fail("frame \(i): \(error.localizedDescription)") }
    }
    guard let lastResult = results.last?.result else { fail("no frames analysed") }

    if wantJSON {
        if framesSpec != nil {
            let rows: [[String: Any]] = results.map { entry in
                var row: [String: Any] = ["frame": entry.frame]
                if let s = entry.result.scalar, s.isFinite { row["scalar"] = s }
                if let data = try? JSONEncoder().encode(entry.result.summary),
                   let obj = try? JSONSerialization.jsonObject(with: data) { row["summary"] = obj }
                return row
            }
            print(prettyJSONString(["tool": toolId, "frames": rows]))
        } else {
            print(prettyJSONString(resultObject(lastResult)))
        }
    } else {
        print("file:  \(path)")
        print("tool:  \(toolId) — \(title)")
        print(framesSpec == nil ? "frame: \(indices[0]) of \(trajectory.count)"
                                : "frames: \(indices.count) of \(trajectory.count) (\(indices.first!)…\(indices.last!))")
        print("")
        printAligned(lastResult.summary.map { [$0.label, $0.value, $0.unit ?? ""] })
        if let p = lastResult.profile, !p.values.isEmpty {
            print("\nprofile — \(p.axisLabel) vs \(p.valueLabel):")
            var rows: [[String]] = [["CENTRE", "VALUE", "COUNT"]]
            for (i, c) in p.centers.enumerated() {
                rows.append([String(format: "%.4g", c), String(format: "%.6g", p.values[i]), "\(p.counts[i])"])
            }
            printAligned(rows, indent: "  ")
        }
        if framesSpec != nil {
            print("\ntime series:")
            var rows: [[String]] = [["FRAME", "SCALAR"]]
            for entry in results {
                rows.append(["\(entry.frame)", entry.result.scalar.map { String(format: "%.6g", $0) } ?? "—"])
            }
            printAligned(rows, indent: "  ")
        }
        for note in lastResult.notes { print("note: \(note)") }
    }

    if let out = csvOut {
        var lines: [String] = ["# summary (frame \(results.last!.frame))", "label,value,unit"]
        lines += lastResult.summary.map {
            "\(csvField($0.label)),\(csvField($0.value)),\(csvField($0.unit ?? ""))"
        }
        if let p = lastResult.profile, !p.values.isEmpty {
            lines += ["# profile: \(p.axisLabel) vs \(p.valueLabel)", "center,value,count"]
            for (i, c) in p.centers.enumerated() { lines.append("\(c),\(p.values[i]),\(p.counts[i])") }
        }
        if framesSpec != nil {
            lines += ["# frames", "frame,scalar"]
            for entry in results {
                let scalar = entry.result.scalar.map { "\($0)" } ?? ""
                lines.append("\(entry.frame),\(scalar)")
            }
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            print("\nwrote \(lines.count) CSV lines → \(out)")
        } catch { fail("write failed: \(error.localizedDescription)") }
    }

case "decimate":
    guard let path = args.first else { fail("usage: mdengine decimate <file> --every N [-o out]") }
    args.removeFirst()
    guard let everyStr = takeOption("--every", &args), let every = Int(everyStr), every > 1 else {
        fail("decimate needs --every N (N > 1)")
    }
    let out = takeOption("-o", &args)
        ?? (path as NSString).deletingPathExtension + ".every\(every).xyz"
    let charges = takeFlag("--charges", &args)
    let frames = readFrames(path)
    guard !frames.isEmpty else { fail("no complete frames found in \(path)") }
    var kept = stride(from: 0, to: frames.count, by: every).map { frames[$0] }
    if (frames.count - 1) % every != 0 { kept.append(frames.last!) }  // always keep final state
    do {
        try TrajectoryWriter.xyz(kept, comment: "Decimated 1/\(every) from \(path)", charges: charges)
            .write(toFile: out, atomically: true, encoding: .utf8)
        print("kept \(kept.count)/\(frames.count) frames → \(out)")
    } catch { fail("write failed: \(error.localizedDescription)") }

case "run":
    if takeFlag("--gpu", &args) {
        guard let input = args.first else { fail("usage: mdengine run --gpu <input> [--label S] [--gpu-type T] [--wall-hours H] [--no-wait]") }
        args.removeFirst()
        let label = takeOption("--label", &args)
        let gpu = takeOption("--gpu-type", &args) ?? "any"
        let wallH = Double(takeOption("--wall-hours", &args) ?? "") ?? 4
        let estMin = Double(takeOption("--estimate-min", &args) ?? "") ?? 60
        let noWait = takeFlag("--no-wait", &args)
        var runner = takeOption("--runner", &args)                          // "openmm" runs python3 {input} on the OpenMM image
        var launch = takeOption("--launch", &args) ?? "default"
        if runner == "openmm" && launch == "default" { launch = "python3 {input}" }
        let force = takeFlag("--force", &args)
        let client: HostedClient
        do { client = try HostedClient.fromSavedCredentials() } catch { fail(error.localizedDescription) }
        if runner == nil || runner == "lammps" {                     // preflight BEFORE spend (GJOB-118), routed (GJOB-116)
            let caps = try? client.capabilities()
            let rate = caps?.rates?[gpu] ?? caps?.rates?["any"]
            let (routed, pf) = DeckPreflight.route(input: URL(fileURLWithPath: (input as NSString).expandingTildeInPath), caps: caps)
            for l in pf.lines(rateHint: rate.map { String(format: "$%.2f/h", $0) }) { FileHandle.standardError.write(Data("preflight: \(l)\n".utf8)) }
            if pf.needsAttention && !force {
                fail(pf.ok ? "not submitted: this deck would not use the GPU (add --force to run it on the pod's CPU cores anyway)"
                           : "not submitted: the deck needs styles no hosted image has (add --force to submit anyway; it will fail at startup)")
            }
            if let routed { runner = routed }                         // same decision the endpoint makes at start; make it explicit
        }
        let spec = HostedJobSpec(input: input, label: label, gpu: gpu,
                                 wallLimitS: Int(wallH * 3600), estimateS: Int(estMin * 60), launch: launch, runner: runner)
        let id: String
        do { id = try client.submit(input: input, spec: spec) } catch { fail(error.localizedDescription) }
        print("mdengine: submitted \(id) → \(client.base.host ?? "endpoint") (gpu \(gpu), wall limit \(wallH) h)")
        if noWait {
            print("poll:  mdengine job \(id)\nfetch: mdengine job \(id) --fetch")
            exit(0)
        }
        exit(hostedWaitAndFetch(client, id))
    }
    guard let input = args.first else { fail("usage: mdengine run <input> [--threads N] [--lmp PATH]") }
    args.removeFirst()
    let threads = Int(takeOption("--threads", &args) ?? "") ?? performanceCores()
    guard let lmp = takeOption("--lmp", &args) ?? findLAMMPS() else {
        fail("no LAMMPS binary found (set $MDENGINE_LMP or install lammps)")
    }
    let logFile = takeOption("--log", &args)
    let inputURL = URL(fileURLWithPath: input)
    guard FileManager.default.fileExists(atPath: inputURL.path) else { fail("no such input: \(input)") }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: lmp)
    // -sf omp -pk omp N is what actually engages the OPENMP package;
    // OMP_NUM_THREADS alone does not accelerate anything.
    var lmpArgs = ["-in", inputURL.lastPathComponent, "-sf", "omp", "-pk", "omp", "\(threads)"]
    if let logFile { lmpArgs += ["-log", logFile] }
    task.arguments = lmpArgs
    task.currentDirectoryURL = inputURL.deletingLastPathComponent()
    var env = ProcessInfo.processInfo.environment
    env["OMP_NUM_THREADS"] = "\(threads)"
    if let potentials = potentialsDir(for: lmp) { env["LAMMPS_POTENTIALS"] = potentials }
    task.environment = env
    // Inherit stdio so thermo output streams live to the terminal.
    print("mdengine: \(lmp) -sf omp -pk omp \(threads) -in \(inputURL.lastPathComponent)")
    do { try task.run() } catch { fail("failed to launch LAMMPS: \(error.localizedDescription)") }
    task.waitUntilExit()
    exit(task.terminationStatus)

case "login":
    guard let key = args.first, key.hasPrefix("mde_") else { fail("usage: mdengine login <mde_key> [--endpoint URL]") }
    args.removeFirst()
    let endpoint = takeOption("--endpoint", &args)
    let creds = HostedCredentials(apiKey: key, endpoint: endpoint)
    do {
        let acct = try HostedClient(credentials: creds).me()   // verify before storing
        try creds.save()
        print("logged in — balance $\(String(format: "%.2f", acct.balance_usd)); key stored in \(HostedCredentials.fileURL.path) (0600)")
    } catch { fail(error.localizedDescription) }

case "capabilities":
    // mdengine capabilities            -> what the hosted runner can do
    // mdengine capabilities <deck.in>  -> preflight this deck (exit 2 if it would fail or not use the GPU)
    let client: HostedClient
    do { client = try HostedClient.fromSavedCredentials() } catch { fail(error.localizedDescription) }
    let caps: HostedCapabilities
    do { caps = try client.capabilities() } catch { fail(error.localizedDescription) }
    if let deck = args.first {
        let (routed, pf) = DeckPreflight.route(input: URL(fileURLWithPath: (deck as NSString).expandingTildeInPath), caps: caps)
        let lines = pf.lines(rateHint: caps.rates?["any"].map { String(format: "$%.2f/h", $0) })
        print(lines.isEmpty ? "ok: every style is available and the pair force runs on the GPU" : lines.joined(separator: "\n"))
        print("runner: \(routed ?? caps.defaultRunner)  gpu-accelerated: \(pf.gpu.count)  cpu-only: \(pf.cpuOnly.count)  missing: \(pf.missing.count)  uses_gpu: \(pf.usesGPU.map { String($0) } ?? "unknown")")
        exit(pf.needsAttention ? 2 : 0)
    }
    for (name, r) in caps.runners.sorted(by: { $0.key < $1.key }) {
        var line = "\(name): \(r.engine ?? "?")"
        if let v = r.lammps_version { line += " \(v)" }
        if let img = r.image { line += "  image \(img)" }
        if let p = r.packages { line += "\n  packages (\(p.count)): \(p.joined(separator: " "))" }
        if let st = r.styles {
            let pairs = st["pair"] ?? [:]
            line += "\n  pair styles: \(pairs.count), GPU-accelerated: \(pairs.values.filter(\.gpu).count)"
            for cat in ["fix", "compute", "kspace", "bond", "angle"] { if let t = st[cat] { line += "  \(cat) \(t.values.filter(\.gpu).count)/\(t.count)" } }
        }
        print(line)
    }
    print("check a deck: mdengine capabilities <deck.in>")

case "account":
    do {
        let client = try HostedClient.fromSavedCredentials()
        let acct = try client.me()
        print("endpoint: \(client.base.absoluteString)")
        print("balance:  $\(String(format: "%.2f", acct.balance_usd))")
        let rates = acct.rate_table.sorted { $0.key < $1.key }.map { "\($0.key) $\(String(format: "%.2f", $0.value))/h" }
        print("rates:    \(rates.joined(separator: ", "))")
        print("credits:  https://forcefieldsilicon.com/mdengine")
    } catch { fail(error.localizedDescription) }

case "jobs":
    do {
        let jobs = try HostedClient.fromSavedCredentials().list()
        if jobs.isEmpty { print("(no hosted jobs)") }
        for j in jobs { print(j.summary + (j.created.map { "  \($0)" } ?? "")) }
    } catch { fail(error.localizedDescription) }

case "job":
    guard let id = args.first else { fail("usage: mdengine job <id> [--log|--fetch|--cancel|--wait]") }
    args.removeFirst()
    let client: HostedClient
    do { client = try HostedClient.fromSavedCredentials() } catch { fail(error.localizedDescription) }
    do {
        if takeFlag("--cancel", &args) {
            print(try client.cancel(id).summary)
        } else if takeFlag("--fetch", &args) {
            let dir = try client.fetch(id)
            print("results → \(dir.path)")
            if let t = HostedClient.primaryTrajectory(in: dir) { print("trajectory: \(t.path)\nopen: mdengine gui && open -a MDEngine \(shellQuoteCLI(t.path))") }
        } else if takeFlag("--wait", &args) {
            exit(hostedWaitAndFetch(client, id))
        } else {
            let s = try client.status(id)
            print(s.summary)
            _ = takeFlag("--log", &args)   // status always includes the thermo tail; --log is accepted for symmetry
            for line in (s.thermo_tail ?? []).suffix(12) { print("  " + line) }
        }
    } catch { fail(error.localizedDescription) }

case "gui":
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-a", "MDEngine"]
    try? task.run()
    task.waitUntilExit()

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command '\(command)'\n\n" + usage)
}
