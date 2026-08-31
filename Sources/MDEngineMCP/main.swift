//
//  mdengine-mcp — MCP (Model Context Protocol) stdio server for MDEngine.
//  Minimal hand-rolled JSON-RPC 2.0 loop. Trajectory tools plus a detached
//  job runner: submitted LAMMPS runs survive this server's death and the
//  machine's display sleep (caffeinate -i), with state kept on disk.
//

import Foundation
import LAMMPSCore

// MARK: - JSON-RPC plumbing

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(_ id: Any, _ payload: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": payload])
}

func replyError(_ id: Any, code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func replyText(_ id: Any, _ text: String, isError: Bool = false) {
    reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
}

func err(_ message: String) -> NSError {
    NSError(domain: "mdengine", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - Shared helpers

func readText(path: String) throws -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw err("cannot read \(path)")
    }
    return text
}

func parseFrames(path: String) throws -> [[Arv]] {
    let frames = TrajectoryReader.parseFrames(try readText(path: path))
    guard !frames.isEmpty else { throw err("no complete frames in \(path)") }
    return frames
}

func performanceCores() -> Int {
    var n: Int32 = 0
    var len = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.physicalcpu", &n, &len, nil, 0) == 0, n > 0 { return Int(n) }
    return max(1, ProcessInfo.processInfo.processorCount / 2)
}

func findLAMMPS() -> String? {
    if let env = ProcessInfo.processInfo.environment["MDENGINE_LMP"],
       FileManager.default.isExecutableFile(atPath: env) { return env }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
    for name in ["lmp_mpi", "lmp_serial", "lmp"] {
        for dir in path.split(separator: ":") {
            let c = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
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

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Job store

/// Jobs live in ~/.mdengine/jobs/<id>/ : job.json, log.lammps, stdout.log,
/// exitcode. The LAMMPS process is wrapped in `sh -c 'caffeinate -i …; echo
/// $? > exitcode'`, so it keeps the machine awake, survives this server's
/// death (orphans are reparented, not killed), and its exit code is recorded
/// even if nobody is watching.
enum Jobs {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mdengine/jobs")

    static func dir(_ id: String) -> URL { root.appendingPathComponent(id) }

    static func meta(_ id: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir(id).appendingPathComponent("job.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// running | done(exit N) | vanished (no exitcode, pid gone — e.g. reboot)
    static func state(_ id: String) -> String {
        let exitFile = dir(id).appendingPathComponent("exitcode")
        if let s = try? String(contentsOf: exitFile, encoding: .utf8) {
            let code = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return code == "0" ? "done (exit 0)" : "FAILED (exit \(code))"
        }
        if let pid = meta(id)?["pid"] as? Int32, kill(pid, 0) == 0 { return "running" }
        return "vanished (no exit code, process gone)"
    }

    /// Last thermo-style lines of the LAMMPS log: numeric rows, plus headers
    /// and the wall-time summary when present.
    static func progress(_ id: String, lines: Int = 6) -> String {
        let log = dir(id).appendingPathComponent("log.lammps")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else {
            return "(no log yet)"
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let interesting = all.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Step") || t.hasPrefix("Total wall time") || t.hasPrefix("ERROR") { return true }
            let fields = t.split(separator: " ", omittingEmptySubsequences: true)
            return fields.count >= 3 && fields.allSatisfy { Double($0) != nil }
        }
        return interesting.suffix(lines).joined(separator: "\n")
    }

    static func submit(input: String, threads: Int, label: String?) throws -> String {
        guard let lmp = findLAMMPS() else { throw err("no LAMMPS binary found (set $MDENGINE_LMP)") }
        let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw err("no such input: \(input)")
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let slug = (label ?? inputURL.deletingPathExtension().lastPathComponent)
            .lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        let id = "MDJOB-\(stamp).\(slug)"
        let jobDir = dir(id)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        let logPath = jobDir.appendingPathComponent("log.lammps").path
        let outPath = jobDir.appendingPathComponent("stdout.log").path
        let exitPath = jobDir.appendingPathComponent("exitcode").path

        // Run in the INPUT's directory: decks reference data/potential files
        // relative to themselves. Bookkeeping goes to the job dir by absolute path.
        let cmd = "/usr/bin/caffeinate -i \(shellQuote(lmp)) -in \(shellQuote(inputURL.lastPathComponent)) "
                + "-sf omp -pk omp \(threads) -log \(shellQuote(logPath)) "
                + "> \(shellQuote(outPath)) 2>&1; echo $? > \(shellQuote(exitPath))"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        task.currentDirectoryURL = inputURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["OMP_NUM_THREADS"] = "\(threads)"
        if let potentials = potentialsDir(for: lmp) { env["LAMMPS_POTENTIALS"] = potentials }
        task.environment = env
        try task.run()

        let metaObj: [String: Any] = [
            "id": id, "input": inputURL.path, "threads": threads, "lmp": lmp,
            "pid": task.processIdentifier, "started": Date().timeIntervalSince1970,
            "cwd": inputURL.deletingLastPathComponent().path,
        ]
        let data = try JSONSerialization.data(withJSONObject: metaObj, options: [.prettyPrinted])
        try data.write(to: jobDir.appendingPathComponent("job.json"))
        return id
    }

    static func cancel(_ id: String) throws -> String {
        guard let pid = meta(id)?["pid"] as? Int32 else { throw err("unknown job \(id)") }
        guard kill(pid, 0) == 0 else { return "\(id): process already gone" }
        // Terminate the lmp/caffeinate children first, then the sh wrapper.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", "\(pid)"]
        try? pkill.run()
        pkill.waitUntilExit()
        kill(pid, SIGTERM)
        return "\(id): sent SIGTERM"
    }

    static func list() -> String {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter({ $0.hasPrefix("MDJOB-") }).sorted() else { return "(no jobs)" }
        if ids.isEmpty { return "(no jobs)" }
        return ids.map { id in
            let started = (meta(id)?["started"] as? Double)
                .map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "?"
            return "\(id) | \(state(id)) | started \(started)"
        }.joined(separator: "\n")
    }
}

// MARK: - Tool definitions

let toolDefs: [[String: Any]] = [
    ["name": "trajectory_info",
     "description": "Inspect an MD trajectory (XYZ / extended-XYZ or native LAMMPS dump; safe on in-flight dumps still being written — reports complete frames): frame count, atoms per frame, element histogram of the last frame, bounding box in Å.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string", "description": "Path to the trajectory file"]],
                     "required": ["path"]]],
    ["name": "export_frame",
     "description": "Write one frame of a trajectory to a new plain-XYZ file.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "out": ["type": "string", "description": "Output file path"],
                                    "frame": ["type": "string", "description": "'first', 'last' (default), or a 0-based index"],
                                    "charges": ["type": "boolean", "description": "Write extended-XYZ with per-atom charge (q) column"]],
                     "required": ["path", "out"]]],
    ["name": "decimate",
     "description": "Keep every Nth frame of a trajectory (the final frame is always kept). Use to shrink huge trajectories before viewing.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "every": ["type": "integer", "description": "Keep every Nth frame; N > 1"],
                                    "out": ["type": "string", "description": "Output file path"]],
                     "required": ["path", "every", "out"]]],
    ["name": "submit_lammps",
     "description": "Submit a LAMMPS input script as a DETACHED background job: keeps the machine awake (caffeinate), survives this server exiting, records its exit code. Runs in the input's own directory so relative data/potential paths work. Returns a job id — poll with job_status.",
     "inputSchema": ["type": "object",
                     "properties": ["input": ["type": "string", "description": "Path to the LAMMPS input script"],
                                    "threads": ["type": "integer", "description": "OpenMP threads (default: performance-core count)"],
                                    "label": ["type": "string", "description": "Short slug for the job id"]],
                     "required": ["input"]]],
    ["name": "job_status",
     "description": "State of a submitted job (running / done / FAILED / vanished) plus the latest thermo lines from its LAMMPS log.",
     "inputSchema": ["type": "object",
                     "properties": ["job_id": ["type": "string"]],
                     "required": ["job_id"]]],
    ["name": "job_log",
     "description": "Tail of a job's LAMMPS log (thermo output, errors).",
     "inputSchema": ["type": "object",
                     "properties": ["job_id": ["type": "string"],
                                    "lines": ["type": "integer", "description": "How many lines (default 40)"]],
                     "required": ["job_id"]]],
    ["name": "list_jobs",
     "description": "List all submitted LAMMPS jobs and their states.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "cancel_job",
     "description": "Terminate a running job (SIGTERM to LAMMPS and its wrapper).",
     "inputSchema": ["type": "object",
                     "properties": ["job_id": ["type": "string"]],
                     "required": ["job_id"]]],
    ["name": "run_lammps",
     "description": "Run a SHORT LAMMPS input synchronously and return the output tail. Blocks the call — for anything longer than ~a minute use submit_lammps instead.",
     "inputSchema": ["type": "object",
                     "properties": ["input": ["type": "string", "description": "Path to the LAMMPS input script"],
                                    "threads": ["type": "integer", "description": "OpenMP threads (default: performance-core count)"]],
                     "required": ["input"]]],
]

// MARK: - Tool implementations

func callTool(_ name: String, _ a: [String: Any]) throws -> String {
    switch name {
    case "trajectory_info":
        guard let path = a["path"] as? String else { throw err("invalid arguments: path") }
        let frames = try parseFrames(path: path)
        let counts = frames.map(\.count)
        let last = frames.last!
        var histogram: [String: Int] = [:]
        for atom in last { histogram[atom.element, default: 0] += 1 }
        let elements = histogram.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let xs = last.map(\.x), ys = last.map(\.y), zs = last.map(\.z)
        func span(_ v: [Double]) -> String { String(format: "%.2f…%.2f", v.min()!, v.max()!) }
        let atoms = Set(counts).count == 1 ? "\(counts[0]) per frame"
            : "varies \(counts.min()!)–\(counts.max()!) (first \(counts.first!), last \(counts.last!))"
        let fields = TrajectoryReader.dumpFields((try? readText(path: path)) ?? "")
            .map { "\nfields: \($0.joined(separator: " "))" } ?? ""
        let charges = last.contains(where: { $0.charge != nil }) ? "\ncharges: present (q)" : ""
        return """
        file: \(path)
        frames: \(frames.count)
        atoms: \(atoms)
        last frame elements: \(elements)
        bbox (Å): x \(span(xs)) | y \(span(ys)) | z \(span(zs))
        """ + fields + charges

    case "export_frame":
        guard let path = a["path"] as? String, let out = a["out"] as? String else {
            throw err("invalid arguments: path, out")
        }
        let which = a["frame"] as? String ?? "last"
        let frames = try parseFrames(path: path)
        let frame: [Arv]
        switch which {
        case "last": frame = frames.last!
        case "first": frame = frames.first!
        default:
            guard let n = Int(which), frames.indices.contains(n) else {
                throw err("frame must be 'first', 'last', or 0…\(frames.count - 1)")
            }
            frame = frames[n]
        }
        let charges = a["charges"] as? Bool ?? false
        try TrajectoryWriter.xyz([frame], comment: "Exported by mdengine-mcp — \(path) frame \(which)", charges: charges)
            .write(toFile: out, atomically: true, encoding: .utf8)
        return "wrote \(frame.count) atoms → \(out)\(charges ? " (extended-XYZ with charges)" : "")"

    case "decimate":
        guard let path = a["path"] as? String, let out = a["out"] as? String else {
            throw err("invalid arguments: path, out")
        }
        guard let every = a["every"] as? Int, every > 1 else { throw err("every must be > 1") }
        let frames = try parseFrames(path: path)
        var kept = stride(from: 0, to: frames.count, by: every).map { frames[$0] }
        if (frames.count - 1) % every != 0 { kept.append(frames.last!) }
        try TrajectoryWriter.xyz(kept, comment: "Decimated 1/\(every) from \(path)")
            .write(toFile: out, atomically: true, encoding: .utf8)
        return "kept \(kept.count)/\(frames.count) frames → \(out)"

    case "submit_lammps":
        guard let input = a["input"] as? String else { throw err("invalid arguments: input") }
        let threads = a["threads"] as? Int ?? performanceCores()
        let id = try Jobs.submit(input: input, threads: threads, label: a["label"] as? String)
        return "submitted \(id)\njob dir: \(Jobs.dir(id).path)\npoll with job_status"

    case "job_status":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        guard let meta = Jobs.meta(id) else { throw err("unknown job \(id)") }
        let elapsed = (meta["started"] as? Double)
            .map { String(format: "%.0f s", Date().timeIntervalSince1970 - $0) } ?? "?"
        return """
        \(id): \(Jobs.state(id))  (elapsed \(elapsed), \(meta["threads"] ?? "?") omp threads)
        input: \(meta["input"] ?? "?")
        \(Jobs.progress(id))
        """

    case "job_log":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        let n = a["lines"] as? Int ?? 40
        let log = Jobs.dir(id).appendingPathComponent("log.lammps")
        let alt = Jobs.dir(id).appendingPathComponent("stdout.log")
        guard let text = (try? String(contentsOf: log, encoding: .utf8))
                      ?? (try? String(contentsOf: alt, encoding: .utf8)) else {
            throw err("no log yet for \(id)")
        }
        return text.split(separator: "\n").suffix(n).joined(separator: "\n")

    case "list_jobs":
        return Jobs.list()

    case "cancel_job":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        return try Jobs.cancel(id)

    case "run_lammps":
        guard let input = a["input"] as? String else { throw err("invalid arguments: input") }
        guard let lmp = findLAMMPS() else { throw err("no LAMMPS binary found (set $MDENGINE_LMP)") }
        let threads = a["threads"] as? Int ?? performanceCores()
        let inputURL = URL(fileURLWithPath: input)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: lmp)
        task.arguments = ["-in", inputURL.lastPathComponent, "-sf", "omp", "-pk", "omp", "\(threads)"]
        task.currentDirectoryURL = inputURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["OMP_NUM_THREADS"] = "\(threads)"
        if let potentials = potentialsDir(for: lmp) { env["LAMMPS_POTENTIALS"] = potentials }
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let tail = output.split(separator: "\n").suffix(60).joined(separator: "\n")
        return "exit code \(task.terminationStatus) (\(lmp), \(threads) omp threads)\n…\n\(tail)"

    default:
        throw err("unknown tool \(name)")
    }
}

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

    let method = msg["method"] as? String ?? ""
    let id = msg["id"]

    // Notifications (no id) need no response.
    guard let id else { continue }

    switch method {
    case "initialize":
        let params = msg["params"] as? [String: Any]
        let version = params?["protocolVersion"] as? String ?? "2025-06-18"
        reply(id, ["protocolVersion": version,
                   "capabilities": ["tools": [String: Any]()],
                   "serverInfo": ["name": "mdengine", "version": "0.4.0"]])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": toolDefs])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do { replyText(id, try callTool(name, args)) }
        catch { replyText(id, error.localizedDescription, isError: true) }
    default:
        replyError(id, code: -32601, "method not found: \(method)")
    }
}
