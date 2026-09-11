//
//  mdengine-mcp — MCP (Model Context Protocol) stdio server for MDEngine.
//  Minimal hand-rolled JSON-RPC 2.0 loop. Trajectory tools plus a detached
//  job runner: submitted LAMMPS runs survive this server's death and the
//  machine's display sleep (caffeinate -i), with state kept on disk.
//

import Foundation
import LAMMPSCore
import MDRender

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
    // Trajectories are loaded whole; refuse sizes that would thrash the machine.
    if let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
       bytes > 2_000_000_000 {
        throw err("\(path) is \(bytes / 1_000_000) MB — mdengine loads whole trajectories "
                + "into memory (limit 2 GB). Decimate or split the file first.")
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw err("cannot read \(path)")
    }
    return text
}

func parseFrames(path: String) throws -> [[Arv]] {
    guard FileManager.default.fileExists(atPath: path) else { throw err("no such file: \(path)") }
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    guard (size ?? 0) < 2_000_000_000 else {
        throw err("\(path) is \((size ?? 0) / 1_000_000) MB (limit 2 GB) — decimate first")
    }
    let frames = try TrajectoryReader.parseFrames(contentsOf: URL(fileURLWithPath: path))
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
    // GUI-launched MCP hosts (Claude Desktop) pass a minimal PATH without
    // Homebrew — always probe the standard install dirs as well.
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin"
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

    /// The remote host a job runs on, when job.json carries one.
    static func remoteHost(_ id: String) -> RemoteHost? {
        guard let name = meta(id)?["host"] as? String else { return nil }
        return try? RemoteHosts.resolve(name)
    }

    /// running | done(exit N) | vanished (no exitcode, pid gone — e.g. reboot)
    static func state(_ id: String) -> String {
        if let h = remoteHost(id) { return RemoteJobs.state(id, host: h) }
        let exitFile = dir(id).appendingPathComponent("exitcode")
        if let s = try? String(contentsOf: exitFile, encoding: .utf8) {
            let code = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return code == "0" ? "done (exit 0)" : "FAILED (exit \(code))"
        }
        if FileManager.default.fileExists(atPath: dir(id).appendingPathComponent("cancelled").path) { return "cancelled" }
        if let pid = meta(id)?["pid"] as? Int32, kill(pid, 0) == 0 { return "running" }
        return "vanished (no exit code, process gone)"
    }

    /// Last thermo-style lines of the LAMMPS log: numeric rows, plus headers
    /// and the wall-time summary when present.
    static func progress(_ id: String, lines: Int = 6) -> String {
        let log = dir(id).appendingPathComponent("log.lammps")
        let text: String
        if let h = remoteHost(id) {
            text = RemoteJobs.logTail(id, host: h, lines: 60)
        } else if let local = try? String(contentsOf: log, encoding: .utf8) {
            text = local
        } else {
            return "(no log yet)"
        }
        let all = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
        let interesting = all.filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if let h = remoteHost(id) { return RemoteJobs.cancel(id, host: h) }
        guard let pid = meta(id)?["pid"] as? Int32 else { throw err("unknown job \(id)") }
        guard kill(pid, 0) == 0 else { return "\(id): process already gone" }
        // Terminate the lmp/caffeinate children first, then the sh wrapper.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", "\(pid)"]
        try? pkill.run()
        pkill.waitUntilExit()
        kill(pid, SIGTERM)
        try? ISO8601DateFormatter().string(from: Date()).write(to: dir(id).appendingPathComponent("cancelled"), atomically: true, encoding: .utf8)
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
    ["name": "z_profile",
     "description": "DEPRECATED alias of analyze(tool: 'z_profile') — kept for callers of MCP Registry ≤ 0.6.x; prefer `analyze`. Depth analysis of a deposition/oxidation trajectory: locates the substrate's top surface plane along z (mean z of the top 5% of substrate atoms), then reports probe-atom penetration depths below it, at-surface and above counts, mean bound-probe charge (when the dump has q), and a z histogram relative to the surface. Defaults: substrate = most abundant element, probe = second.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string", "description": "Path to the trajectory file"],
                                    "frame": ["type": "string", "description": "'first', 'last' (default), or a 0-based index"],
                                    "substrate": ["type": "string", "description": "Substrate element/type token (default: most abundant)"],
                                    "probe": ["type": "string", "description": "Deposited-species element/type token (default: second most abundant)"]],
                     "required": ["path"]]],
    ["name": "analyze",
     "description": "Run a registered MDEngine analysis tool on a trajectory frame (the same tools the app's inspector runs). Call it WITHOUT `tool` first: that returns the catalogue — each tool's id, use-case category, what it produces (per-atom field / profile / scalar / time series), what it requires, and its default parameters. Then call it with `tool` for the result: a summary table, a binned profile, a scalar, and notes. With `frames`, the same scalar over a range of frames (a time series).",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string", "description": "Path to the trajectory file"],
                                    "tool": ["type": "string", "description": "Registered tool id (e.g. 'z_profile', 'column_field'); omit for the catalogue"],
                                    "frame": ["type": "string", "description": "'first', 'last' (default), or a 0-based index"],
                                    "frames": ["type": "string", "description": "Time series over 'all', 'a-b', or 'a-b:stride' (0-based, inclusive) — returns one scalar + summary per frame instead of one frame's result"],
                                    "params": ["type": "object", "description": "Tool parameters, merged over the tool's defaults (see the catalogue's default_parameters)"],
                                    "reference_frame": ["type": "integer", "description": "Reference frame index for tools that measure change (Deformation); default 0"],
                                    "include_field": ["type": "boolean", "description": "Include the per-atom field VALUES (one number per atom — large). Default false: only the palette, legend and atom count are returned."]],
                     "required": ["path"]]],
    ["name": "render_video",
     "description": "Render a trajectory into an MP4 (H.264) or animated GIF via the same Metal renderer the app uses. Annotations (scale bar + frame counter) baked by default. Camera defaults to the home view; pass yaw/pitch degrees to frame the shot (front view of a z-up slab: pitch -90). Stride defaults to ~15 s of video. Synchronous — a long trajectory at 4K can take minutes.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string", "description": "Trajectory file"],
                                    "out": ["type": "string", "description": "Output .mp4 or .gif path (format follows the extension)"],
                                    "width": ["type": "integer", "description": "Pixels (default 1920; GIF default 640)"],
                                    "height": ["type": "integer", "description": "Pixels (default 1080; GIF default 360)"],
                                    "fps": ["type": "integer", "description": "Video frame rate (default 30; GIF capped 15)"],
                                    "stride": ["type": "integer", "description": "Render every Nth trajectory frame (default: auto for ~15 s)"],
                                    "yaw_deg": ["type": "number", "description": "Camera yaw in degrees (default 0)"],
                                    "pitch_deg": ["type": "number", "description": "Camera pitch in degrees (default 0 = top view for z-up data; -90 = front)"],
                                    "distance": ["type": "number", "description": "Camera distance in model units (default 2.8; smaller = closer)"],
                                    "orthographic": ["type": "boolean", "description": "Orthographic projection (default false)"],
                                    "orbit_dps": ["type": "number", "description": "Cinematic yaw rotation, degrees per second of video (default 0)"],
                                    "annotations": ["type": "boolean", "description": "Bake scale bar + frame counter (default true)"],
                                    "elements": ["type": "string", "description": "Map numeric type tokens to elements by position, e.g. 'O,Al' (type 1→O red, 2→Al silver) — colors follow the element"],
                                    "style": ["type": "string", "description": "'contrast': auto best-visibility — minority species enlarged 1.8× and recolored to pop against the substrate"],
                                    "colors": ["type": "string", "description": "Per-element colors, e.g. 'O=red,Al=#3366ff' (named colors or #rrggbb); overrides palette/style"],
                                    "sizes": ["type": "string", "description": "Per-element relative sizes, e.g. 'O=1.8,Al=1'"]],
                     "required": ["path", "out"]]],
    ["name": "render_image",
     "description": "Render ONE trajectory frame to a PNG through the same Metal renderer — lets an agent SEE a simulation state. Same camera/style/annotation arguments as render_video; frame selects which snapshot.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string", "description": "Trajectory file"],
                                    "out": ["type": "string", "description": "Output .png path"],
                                    "frame": ["type": "string", "description": "'first', 'last' (default), or a 0-based index"],
                                    "width": ["type": "integer", "description": "Pixels (default 1280)"],
                                    "height": ["type": "integer", "description": "Pixels (default 960)"],
                                    "yaw_deg": ["type": "number"], "pitch_deg": ["type": "number", "description": "0 = top view for z-up data; -90 = front"],
                                    "distance": ["type": "number", "description": "Camera distance (default 2.8; smaller = closer)"],
                                    "orthographic": ["type": "boolean"],
                                    "annotations": ["type": "boolean", "description": "Scale bar + frame counter (default true)"],
                                    "overlay": ["type": "string", "description": "Analysis tool id whose per-atom field colours the atoms (e.g. column_field); legend baked bottom-right. See analyze for the catalogue."],
                                    "overlay_params": ["type": "object", "description": "Parameters for the overlay tool (merged over its defaults)"],
                                    "bonds": ["type": "boolean", "description": "Draw covalent bonds (distance criterion, Cordero radii) and, when the file carries residue labels, the Cα backbone trace (default false)"],
                                    "elements": ["type": "string", "description": "Type-token→element mapping, e.g. 'O,Al'"],
                                    "style": ["type": "string", "description": "'contrast' auto best-visibility preset"],
                                    "colors": ["type": "string", "description": "'O=red,Al=#3366ff'"],
                                    "sizes": ["type": "string", "description": "'O=1.8'"]],
                     "required": ["path", "out"]]],
    ["name": "export_frame",
     "description": "Write one frame of a trajectory to a new plain-XYZ file.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "out": ["type": "string", "description": "Output file path"],
                                    "frame": ["type": "string", "description": "'first', 'last' (default), or a 0-based index"],
                                    "charges": ["type": "boolean", "description": "Write extended-XYZ with per-atom charge (q) column"]],
                     "required": ["path", "out"]]],
    ["name": "cloud_capabilities",
     "description": "What the hosted GPU tier can run: LAMMPS version, installed packages, GPU-accelerated vs CPU-only styles. With `input`, preflights that deck the way submit_lammps host=cloud does — styles missing from the hosted image (the run would exit at startup), CPU-only styles, and whether the pair force will use the GPU. Nothing is submitted or billed.",
     "inputSchema": ["type": "object",
                     "properties": ["input": ["type": "string", "description": "Optional LAMMPS input path to preflight"]]]],
    ["name": "decimate",
     "description": "Keep every Nth frame of a trajectory (the final frame is always kept). Use to shrink huge trajectories before viewing.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "every": ["type": "integer", "description": "Keep every Nth frame; N > 1"],
                                    "out": ["type": "string", "description": "Output file path"]],
                     "required": ["path", "every", "out"]]],
    ["name": "submit_lammps",
     "description": "Submit a LAMMPS input script as a DETACHED background job — locally (keeps the machine awake, survives this server exiting, records its exit code) or on a configured REMOTE host (~/.mdengine/hosts.json: the deck's directory is rsynced up, minus trajectories/checkpoints/logs, and LAMMPS runs there under nohup with its exit code recorded remotely; a GPU box is just a host whose launch template carries the KOKKOS flags). host='cloud' sends the deck to the hosted GPU tier (RTX 4090, KOKKOS; prepaid credits at $2/GPU-h, API key from `mdengine login`) — same job tools, results come back with fetch_job. Runs in the input's own directory so relative data/potential paths work; a remote deck must be self-contained within that directory. Returns a job id — poll with job_status; for remote jobs, fetch_job pulls results back.",
     "inputSchema": ["type": "object",
                     "properties": ["input": ["type": "string", "description": "Path to the LAMMPS input script"],
                                    "threads": ["type": "integer", "description": "OpenMP threads (default: performance-core count locally, or the host's configured threads)"],
                                    "label": ["type": "string", "description": "Short slug for the job id"],
                                    "host": ["type": "string", "description": "Remote host name from hosts.json; 'cloud' = the hosted GPU tier (prepaid credits, API key via `mdengine login`); 'local' forces this machine; omitted = hosts.json default, else local"],
                                    "gpu": ["type": "string", "description": "host=cloud only: any (cheapest) | rtx4090 | a100"],
                                    "wall_hours": ["type": "number", "description": "host=cloud only: hard wall-clock cap in hours (default 4; billed to the cap if hit)"],
                                    "force": ["type": "boolean", "description": "host=cloud only: submit even when preflight says the deck would not use the GPU or needs styles the hosted image lacks"]],
                     "required": ["input"]]],
    ["name": "list_hosts",
     "description": "List the execution hosts configured in ~/.mdengine/hosts.json (ssh target, remote LAMMPS, workdir, launch template) and which is the default.",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "fetch_job",
     "description": "Pull a REMOTE job's outputs (its run directory: dumps, data files, plus log.lammps/stdout.log) back into the local job dir under results/, so trajectory_info / z_profile / render_* can read them. Safe to call while the job is still running (partial dumps parse to complete frames).",
     "inputSchema": ["type": "object",
                     "properties": ["job_id": ["type": "string"],
                                    "include_trajectories": ["type": "boolean", "description": "Also pull *.traj/*.lammpstrj/*.dump (default true — that is usually the point)"]],
                     "required": ["job_id"]]],
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
    ["name": "job_files",
     "description": "List the files a job produced: contents of its run directory (where dumps/logs land per the deck) and its bookkeeping dir, with sizes. Use after job_status says done to locate the output trajectory.",
     "inputSchema": ["type": "object",
                     "properties": ["job_id": ["type": "string"]],
                     "required": ["job_id"]]],
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

// MARK: - Tool metadata (MCP `title` + behaviour annotations, merged into tools/list)
// Annotations follow the MCP spec: readOnlyHint = no environment mutation;
// destructiveHint = may delete/overwrite/terminate; idempotentHint; openWorldHint = talks
// to hosts beyond this machine. Directory listings (e.g. Anthropic's) require them.
private func ann(_ readOnly: Bool, destructive: Bool = false, idempotent: Bool = false, openWorld: Bool = false) -> [String: Any] {
    ["readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": idempotent, "openWorldHint": openWorld]
}
let toolMeta: [String: [String: Any]] = [
    "trajectory_info": ["title": "Trajectory info",        "annotations": ann(true, idempotent: true)],
    "z_profile":       ["title": "Depth (z) profile (deprecated → analyze)", "annotations": ann(true, idempotent: true)],
    "analyze":         ["title": "Analyze (registry tool)","annotations": ann(true, idempotent: true)],
    "render_video":    ["title": "Render trajectory video","annotations": ann(false, idempotent: true)],
    "render_image":    ["title": "Render frame image",     "annotations": ann(false, idempotent: true)],
    "export_frame":    ["title": "Export frame to XYZ",    "annotations": ann(false, idempotent: true)],
    "decimate":        ["title": "Decimate trajectory",    "annotations": ann(false, idempotent: true)],
    "submit_lammps":   ["title": "Submit LAMMPS job",      "annotations": ann(false, openWorld: true)],
    "list_hosts":      ["title": "List execution hosts",   "annotations": ann(true, idempotent: true)],
    "cloud_capabilities": ["title": "Hosted tier capabilities / preflight", "annotations": ann(true, idempotent: true, openWorld: true)],
    "fetch_job":       ["title": "Fetch remote job outputs","annotations": ann(false, idempotent: true, openWorld: true)],
    "job_status":      ["title": "Job status",             "annotations": ann(true, idempotent: true, openWorld: true)],
    "job_log":         ["title": "Job log tail",           "annotations": ann(true, idempotent: true, openWorld: true)],
    "list_jobs":       ["title": "List jobs",              "annotations": ann(true, idempotent: true)],
    "job_files":       ["title": "List job files",         "annotations": ann(true, idempotent: true, openWorld: true)],
    "cancel_job":      ["title": "Cancel job",             "annotations": ann(false, destructive: true, idempotent: true, openWorld: true)],
    "run_lammps":      ["title": "Run LAMMPS (blocking)",  "annotations": ann(false, openWorld: true)],
]
let toolList: [[String: Any]] = toolDefs.map { def in
    var d = def
    if let name = def["name"] as? String, let extra = toolMeta[name] { extra.forEach { d[$0.key] = $0.value } }
    return d
}

// MARK: - Render helpers (render_video / render_image)

let namedColors: [String: SIMD3<Float>] = [
    "red": SIMD3(1.0, 0.2, 0.18), "green": SIMD3(0.2, 0.85, 0.3),
    "blue": SIMD3(0.25, 0.45, 1.0), "yellow": SIMD3(1.0, 0.85, 0.2),
    "orange": SIMD3(1.0, 0.55, 0.1), "cyan": SIMD3(0.2, 0.9, 1.0),
    "magenta": SIMD3(1.0, 0.3, 0.9), "white": SIMD3(0.95, 0.95, 0.95),
    "silver": SIMD3(0.75, 0.76, 0.8), "gray": SIMD3(0.5, 0.5, 0.5),
    "black": SIMD3(0.08, 0.08, 0.08), "purple": SIMD3(0.6, 0.35, 0.95),
]

func parseColor(_ spec: String) throws -> SIMD3<Float> {
    let t = spec.lowercased().trimmingCharacters(in: .whitespaces)
    if let c = namedColors[t] { return c }
    if t.hasPrefix("#"), t.count == 7,
       let v = UInt32(t.dropFirst(), radix: 16) {
        return SIMD3(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255,
                     Float(v & 0xFF) / 255)
    }
    throw err("unknown color '\(spec)' — use \(namedColors.keys.sorted().joined(separator: "/")) or #rrggbb")
}

/// Style from tool args: `style: "contrast"` preset, then explicit
/// `colors: "O=red,Al=#3366ff"` / `sizes: "O=1.8"` override on top.
func parseStyle(_ a: [String: Any], frame: [Arv]) throws -> AtomStyle {
    var style = AtomStyle()
    if let preset = a["style"] as? String {
        guard preset == "contrast" else { throw err("unknown style '\(preset)' — only 'contrast'") }
        style = VideoExporter.contrastStyle(for: frame)
    }
    if let spec = a["colors"] as? String {
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { throw err("colors must be 'Elem=color,...' — got '\(pair)'") }
            style.colors[kv[0].trimmingCharacters(in: .whitespaces)] = try parseColor(String(kv[1]))
        }
    }
    if let spec = a["sizes"] as? String {
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let f = Float(kv[1].trimmingCharacters(in: .whitespaces)),
                  f > 0.05, f <= 10 else {
                throw err("sizes must be 'Elem=factor,...' with 0.05<factor<=10 — got '\(pair)'")
            }
            style.sizes[kv[0].trimmingCharacters(in: .whitespaces)] = f
        }
    }
    return style
}

func parseCamera(_ a: [String: Any]) -> OffscreenRenderer.Camera {
    OffscreenRenderer.Camera(
        yaw: Float((a["yaw_deg"] as? Double ?? 0) * .pi / 180),
        pitch: Float((a["pitch_deg"] as? Double ?? 0) * .pi / 180),
        distance: Float(a["distance"] as? Double ?? 2.8),
        orthographic: a["orthographic"] as? Bool ?? false)
}

func mappedFrames(_ a: [String: Any], _ frames: [[Arv]]) -> [[Arv]] {
    guard let spec = a["elements"] as? String else { return frames }
    return frames.mappingElements(
        spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
}

// MARK: - Analysis registry bridge (`analyze`)

/// Full parse (atoms + box + per-atom columns) — analysis tools need more than
/// `parseFrames`' bare atom lists.
func parseTrajectoryFrames(path: String) throws -> Trajectory {
    guard FileManager.default.fileExists(atPath: path) else { throw err("no such file: \(path)") }
    // Side-file tools accept a run directory / .json / .csv as the anchor (no atoms needed).
    var isDir: ObjCBool = false
    if (FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        || ["json", "csv", "lammps", "log"].contains((path as NSString).pathExtension.lowercased()) {
        return [Frame(atoms: [])]
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    guard size < 2_000_000_000 else {
        throw err("\(path) is \(size / 1_000_000) MB (limit 2 GB) — decimate first")
    }
    let frames = try TrajectoryReader.parseTrajectory(contentsOf: URL(fileURLWithPath: path))
    guard !frames.isEmpty else { throw err("no complete frames in \(path)") }
    return frames
}

/// The registry catalogue, as JSON-ready dictionaries.
func analysisCatalogue() -> [[String: Any]] {
    ToolRegistry.shared.metadata.map { m in
        var entry: [String: Any] = [
            "id": m.id,
            "title": m.title,
            "category": m.category.title,
            "functions": m.functions.map(\.rawValue),
            "requirements": m.requirements.map(\.rawValue),
            "supports_strided_preview": m.supportsStridedPreview,
            "skill": "skills/tools/\(m.id)/SKILL.md",
            "manual": "docs/manual/html/tools.html#\(m.id)",
        ]
        if let data = ToolRegistry.shared.tool(m.id)?.defaultParametersJSON,
           let obj = try? JSONSerialization.jsonObject(with: data) {
            entry["default_parameters"] = obj
        }
        return entry
    }
}

/// Caller parameters layered over the tool's defaults (a malformed value falls
/// back to the tool's own default for that field).
func mergedParametersJSON(toolId: String, overrides: [String: Any]) throws -> Data {
    guard let tool = ToolRegistry.shared.tool(toolId) else {
        let ids = ToolRegistry.shared.metadata.map(\.id).joined(separator: ", ")
        throw err("unknown tool '\(toolId)' — registered: \(ids)")
    }
    var merged = (try? JSONSerialization.jsonObject(with: tool.defaultParametersJSON))
        as? [String: Any] ?? [:]
    for (key, value) in overrides { merged[key] = value }
    return (try? JSONSerialization.data(withJSONObject: merged)) ?? tool.defaultParametersJSON
}

/// Context for `index`; `reference_frame` (default 0) is attached for tools
/// that measure change against another frame (Deformation).
func analysisContext(_ a: [String: Any], frames: Trajectory, index: Int) -> AnalysisContext {
    let ref = a["reference_frame"] as? Int ?? 0
    let source = (a["path"] as? String).map { URL(fileURLWithPath: $0) }
    let gen = abs((a["path"] as? String ?? "").hashValue) % 1_000_000 + 1   // stable within one process
    guard frames.indices.contains(ref) else {
        return AnalysisContext(frameIndex: index, sourceURL: source, trajectory: frames, trajectoryGeneration: gen)
    }
    return AnalysisContext(frameIndex: index, referenceFrame: frames[ref], referenceFrameIndex: ref, sourceURL: source,
                           trajectory: frames, trajectoryGeneration: gen)
}

func resolveFrameIndex(_ spec: String, count: Int) throws -> Int {
    switch spec {
    case "last", "": return count - 1
    case "first": return 0
    default:
        guard let i = Int(spec), (0..<count).contains(i) else {
            throw err("frame must be 'first', 'last', or 0…\(count - 1)")
        }
        return i
    }
}

/// "all" | "a-b" | "a-b:stride" → the frame indices to walk.
func resolveFrameRange(_ spec: String, count: Int) throws -> [Int] {
    if spec == "all" { return Array(0..<count) }
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
    let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count <= 2, bounds.count == 2,
          let lo = Int(bounds[0]), let hi = Int(bounds[1]),
          let step = parts.count == 2 ? Int(parts[1]) : 1,
          step >= 1, lo >= 0, hi < count, lo <= hi else {
        throw err("frames must be 'all', 'a-b' or 'a-b:stride' within 0…\(count - 1)")
    }
    return Array(Swift.stride(from: lo, through: hi, by: step))
}

/// ToolResult as JSON; per-atom values are dropped unless asked for (they are
/// one Float per atom — megabytes through a chat transcript).
func resultJSONObject(_ result: ToolResult, includeField: Bool) throws -> [String: Any] {
    let data = try JSONEncoder().encode(result)
    guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw err("could not encode the tool result")
    }
    if !includeField, var field = obj["field"] as? [String: Any] {
        field["count"] = (field["values"] as? [Any])?.count ?? 0
        field.removeValue(forKey: "values")
        obj["field"] = field
    }
    return obj
}

func prettyJSON(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object,
                                          options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

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

    case "z_profile":
        // Deprecated alias (GJOB-164): the registered ZProfileTool is the one implementation.
        // substrate/probe map onto the tool's parameters; frame passes through unchanged.
        var args: [String: Any] = ["tool": "z_profile"]
        if let path = a["path"] { args["path"] = path }
        if let frame = a["frame"] { args["frame"] = frame }
        var params: [String: Any] = [:]
        if let s = a["substrate"] as? String, !s.isEmpty { params["substrate"] = s }
        if let p = a["probe"] as? String, !p.isEmpty { params["probe"] = p }
        if !params.isEmpty { args["params"] = params }
        return "note: z_profile is a deprecated alias of analyze(tool: \"z_profile\")\n"
             + (try callTool("analyze", args))

    case "analyze":
        guard let path = a["path"] as? String else { throw err("invalid arguments: path") }
        let toolId = (a["tool"] as? String) ?? ""
        guard !toolId.isEmpty else {
            return "registered analysis tools (pass one as `tool`):\n"
                 + (try prettyJSON(analysisCatalogue()))
        }
        guard let tool = ToolRegistry.shared.tool(toolId) else {
            let ids = ToolRegistry.shared.metadata.map(\.id).joined(separator: ", ")
            throw err("unknown tool '\(toolId)' — registered: \(ids)")
        }
        var frames = try parseTrajectoryFrames(path: path)
        var overrides = a["params"] as? [String: Any] ?? [:]
        if frames.count == 1, frames[0].atoms.isEmpty {          // side-file anchor (dir / .json / .csv / log)
            let key = ["fep_results": "jsonPath", "campaign_matrix": "jsonPath",
                       "kinetics_tramd": "csvPath",
                       "pulloff_energetics": "csvPath", "thermo": "logPath"][toolId]
            if let key, !(path as NSString).pathExtension.isEmpty, overrides[key] == nil { overrides[key] = path }
            if let f = a["frame"] as? String, let n = Int(f), n > 0 { frames = Array(repeating: Frame(atoms: []), count: n + 1) }
            if let spec = a["frames"] as? String, !spec.isEmpty {
                throw err("with a side file as `path`, use `frame` (row/edge index); pass the trajectory for `frames`")
            }
        }
        let paramsJSON = try mergedParametersJSON(toolId: toolId, overrides: overrides)
        let includeField = a["include_field"] as? Bool ?? false

        // Time series: one scalar (+ summary) per frame, never the fields.
        if let spec = a["frames"] as? String, !spec.isEmpty {
            let indices = try resolveFrameRange(spec, count: frames.count)
            var rows: [[String: Any]] = []
            for i in indices {
                let result = try tool.analyze(frame: frames[i],
                                              context: analysisContext(a, frames: frames, index: i),
                                              parametersJSON: paramsJSON)
                var row: [String: Any] = ["frame": i]
                if let s = result.scalar, s.isFinite { row["scalar"] = s }
                let summary = try JSONEncoder().encode(result.summary)
                row["summary"] = try JSONSerialization.jsonObject(with: summary)
                rows.append(row)
            }
            return "file: \(path)  tool: \(toolId)  frames: \(indices.count) of \(frames.count)\n"
                 + (try prettyJSON(["tool": toolId, "frames": rows]))
        }

        let index = try resolveFrameIndex((a["frame"] as? String) ?? "last", count: frames.count)
        let result = try tool.analyze(frame: frames[index],
                                      context: analysisContext(a, frames: frames, index: index),
                                      parametersJSON: paramsJSON)
        return "file: \(path)  tool: \(toolId)  frame: \(index) of \(frames.count)\n"
             + (try prettyJSON(try resultJSONObject(result, includeField: includeField)))

    case "render_video":
        guard let path = a["path"] as? String, let out = a["out"] as? String else {
            throw err("invalid arguments: path, out")
        }
        var vframes = try parseFrames(path: path)
        guard vframes.count > 1 else { throw err("trajectory has fewer than 2 frames") }
        if let spec = a["elements"] as? String {
            vframes = vframes.mappingElements(
                spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        let isGIF = out.lowercased().hasSuffix(".gif")
        guard isGIF || out.lowercased().hasSuffix(".mp4") else {
            throw err("out must end in .mp4 or .gif")
        }
        let camera = parseCamera(a)
        let style = try parseStyle(a, frame: vframes.last ?? [])
        let options = VideoExporter.Options(
            width: a["width"] as? Int ?? (isGIF ? 640 : 1920),
            height: a["height"] as? Int ?? (isGIF ? 360 : 1080),
            fps: min(a["fps"] as? Int ?? 30, isGIF ? 15 : 60),
            stride: a["stride"] as? Int ?? 0,
            format: isGIF ? .gif : .mp4,
            annotations: a["annotations"] as? Bool ?? true,
            orbitDegreesPerSecond: a["orbit_dps"] as? Double ?? 0,
            camera: camera,
            style: style)
        let start = Date()
        let written = try VideoExporter.export(frames: vframes, to: URL(fileURLWithPath: out),
                                               options: options)
        let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
        return String(format: "wrote %@: %d video frames (%.1f s at %d fps) from %d trajectory frames, %.1f MB, rendered in %.0f s",
                      out, written, Double(written) / Double(options.fps), options.fps,
                      vframes.count, Double(size ?? 0) / 1_000_000, -start.timeIntervalSinceNow)

    case "render_image":
        guard let path = a["path"] as? String, let out = a["out"] as? String else {
            throw err("invalid arguments: path, out")
        }
        guard out.lowercased().hasSuffix(".png") else { throw err("out must end in .png") }
        var iframes = try parseFrames(path: path)
        iframes = mappedFrames(a, iframes)
        var frameIndex = iframes.count - 1
        switch (a["frame"] as? String) ?? "last" {
        case "last": break
        case "first": frameIndex = 0
        case let f:
            guard let i = Int(f), iframes.indices.contains(i) else {
                throw err("frame must be 'first', 'last', or 0…\(iframes.count - 1)")
            }
            frameIndex = i
        }
        let ioptions = VideoExporter.Options(
            width: a["width"] as? Int ?? 1280,
            height: a["height"] as? Int ?? 960,
            annotations: a["annotations"] as? Bool ?? true,
            camera: parseCamera(a),
            style: try parseStyle(a, frame: iframes[frameIndex]))
        // Optional per-atom colouring by an analysis tool (design §1: overlay = a colour source).
        var overlayField: PerAtomField?
        var overlayNote = ""
        if let toolId = a["overlay"] as? String, !toolId.isEmpty {
            guard let tool = ToolRegistry.shared.tool(toolId) else {
                throw err("unknown overlay tool '\(toolId)' — call analyze without a tool for the catalogue")
            }
            let full = try parseTrajectoryFrames(path: path)
            guard full.indices.contains(frameIndex) else { throw err("overlay: frame out of range") }
            let params = try mergedParametersJSON(toolId: toolId, overrides: a["overlay_params"] as? [String: Any] ?? [:])
            let result = try tool.analyze(frame: full[frameIndex],
                                          context: analysisContext(a, frames: full, index: frameIndex),
                                          parametersJSON: params)
            guard let field = result.field else {
                throw err("tool '\(toolId)' publishes no per-atom field (functions: \(tool.metadata.functions.map(\.rawValue).joined(separator: ", ")))")
            }
            overlayField = field
            overlayNote = ", overlay \(toolId) (\(field.legendTitle))"
        }
        var bondSet: BondSet?
        if a["bonds"] as? Bool == true {
            let full = try parseTrajectoryFrames(path: path)
            if full.indices.contains(frameIndex) { bondSet = BondPerception.perceive(frame: full[frameIndex]) }
        }
        let dims = try VideoExporter.exportPNG(frames: iframes, frameIndex: frameIndex,
                                               to: URL(fileURLWithPath: out), options: ioptions,
                                               overlay: overlayField, bonds: bondSet)
        return "wrote \(out): frame \(frameIndex + 1)/\(iframes.count), \(dims.width)×\(dims.height)\(overlayNote)"

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
        if (a["host"] as? String) == "cloud" {
            let client = try HostedClient.fromSavedCredentials()
            var spec = HostedJobSpec(input: input, label: a["label"] as? String, gpu: a["gpu"] as? String ?? "any",
                                     wallLimitS: Int(((a["wall_hours"] as? Double) ?? 4) * 3600))
            // Preflight before spend (GJOB-118): missing styles or a CPU-only pair style stop the submit unless force=true.
            // Routing (GJOB-116): a deck needing packages beyond the fast default image goes to lammps-full.
            let caps = try? client.capabilities()
            let (routed, pf) = DeckPreflight.route(input: URL(fileURLWithPath: (input as NSString).expandingTildeInPath), caps: caps)
            let pfLines = pf.lines(rateHint: (caps?.rates?[spec.gpu] ?? caps?.rates?["any"]).map { String(format: "$%.2f/h", $0) })
            if pf.needsAttention && (a["force"] as? Bool) != true {
                throw err("not submitted — preflight:\n" + pfLines.joined(separator: "\n") + "\n"
                          + (pf.ok ? "Pass force=true to run it on the pod's CPU cores anyway, or run it locally for free with submit_lammps host=local."
                                   : "Pass force=true to submit anyway (it will fail at startup and bill the launch), or run it locally for free."))
            }
            spec.runner = routed
            let id = try client.submit(input: input, spec: spec)
            return "submitted \(id) to the hosted GPU tier (\(client.base.host ?? "endpoint"), gpu \(spec.gpu), runner \(routed ?? caps?.defaultRunner ?? "lammps"), wall limit \(spec.wall_limit_s / 3600) h)"
                 + (pfLines.isEmpty ? "" : "\npreflight: " + pfLines.joined(separator: "\npreflight: "))
                 + "\nlocal job dir: \(Jobs.dir(id).path)\npoll with job_status (live thermo tail); fetch_job downloads results when done"
        }
        if let host = try RemoteHosts.resolve(a["host"] as? String) {
            let id = try RemoteJobs.submit(host: host, input: input, threads: a["threads"] as? Int,
                                           label: a["label"] as? String)
            return "submitted \(id) on \(host.name) (\(host.ssh))\nremote dir: \(host.workdir)/\(id)\nlocal job dir: \(Jobs.dir(id).path)\npoll with job_status; fetch_job pulls results back"
        }
        let threads = a["threads"] as? Int ?? performanceCores()
        let id = try Jobs.submit(input: input, threads: threads, label: a["label"] as? String)
        return "submitted \(id)\njob dir: \(Jobs.dir(id).path)\npoll with job_status"

    case "cloud_capabilities":
        let client = try HostedClient.fromSavedCredentials()
        let caps = try client.capabilities()
        if let input = a["input"] as? String {
            let (routed, pf) = DeckPreflight.route(input: URL(fileURLWithPath: (input as NSString).expandingTildeInPath), caps: caps)
            let lines = pf.lines(rateHint: caps.rates?["any"].map { String(format: "$%.2f/h", $0) })
            let verdict = !pf.ok ? "REFUSE: no hosted image has styles this deck needs" : pf.usesGPU == false ? "WARN: this deck would not use the GPU"
                        : routed.map { "OK: routed to \($0)" } ?? "OK"
            return "\(verdict)\n" + (lines.isEmpty ? "every style is available and the pair force runs on the GPU\n" : lines.joined(separator: "\n") + "\n")
                 + "runner \(routed ?? caps.defaultRunner), gpu-accelerated \(pf.gpu.count), cpu-only \(pf.cpuOnly.count), missing \(pf.missing.count)"
        }
        var out: [String] = []
        for (name, r) in caps.runners.sorted(by: { $0.key < $1.key }) {
            var line = "\(name): \(r.engine ?? "?") \(r.lammps_version ?? "")"
            if let img = r.image { line += "  image \(img)" }
            if let p = r.packages { line += "\n  packages (\(p.count)): \(p.joined(separator: " "))" }
            if let st = r.styles {
                let pairs = st["pair"] ?? [:]
                line += "\n  pair styles \(pairs.count) (GPU-accelerated \(pairs.values.filter(\.gpu).count)): " + pairs.filter { $0.value.gpu }.keys.sorted().joined(separator: " ")
                for cat in ["fix", "compute", "kspace"] { if let t = st[cat] { line += "\n  \(cat): \(t.values.filter(\.gpu).count)/\(t.count) GPU-accelerated" } }
            }
            out.append(line)
        }
        return out.joined(separator: "\n") + "\nPass input=<deck.in> to preflight a deck."

    case "list_hosts":
        var cloud = "cloud: hosted GPU tier — "
        if let c = try? HostedClient.fromSavedCredentials(), let me = try? c.me() {
            cloud += "\(c.base.host ?? c.base.absoluteString), balance $\(String(format: "%.2f", me.balance_usd)), "
            if let p = me.pricing, p.isJob {
                cloud += "priced by work (\((p.usd_per_gatom_step ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) $\($0.value)" }.joined(separator: ", ")) per billion atom-steps; never more than wall limit × rate)"
            } else {
                cloud += "rates \(me.rate_table.sorted { $0.key < $1.key }.map { "\($0.key) $\($0.value)/h" }.joined(separator: ", "))"
            }
        } else {
            cloud += "no API key (mdengine login <mde_key>; keys come with a credit pack at forcefieldsilicon.com/mdengine)"
        }
        return RemoteHosts.describe() + "\n" + cloud

    case "fetch_job":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        guard Jobs.meta(id) != nil else { throw err("unknown job \(id)") }
        if HostedClient.cloudMeta(id) != nil {
            let dir = try HostedClient.fromSavedCredentials().fetch(id)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
            let traj = HostedClient.primaryTrajectory(in: dir).map { "\ntrajectory: \($0.path)" } ?? ""
            return "fetched \(names.count) files → \(dir.path)\n" + names.prefix(50).map { "  " + $0 }.joined(separator: "\n") + traj
        }
        guard let host = Jobs.remoteHost(id) else { return "\(id) ran locally — its files are already in place (see job_files)" }
        let withTraj = a["include_trajectories"] as? Bool ?? true
        let excludes = withTraj ? [".git"] : RemoteHost.defaultExcludes
        return try RemoteJobs.fetch(id, host: host, excludes: excludes)

    case "job_status":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        guard let meta = Jobs.meta(id) else { throw err("unknown job \(id)") }
        if HostedClient.cloudMeta(id) != nil {
            let s = try HostedClient.fromSavedCredentials().status(id)
            let tail = (s.thermo_tail ?? []).suffix(8).joined(separator: "\n")
            return "\(s.summary)  · hosted GPU tier\ninput: \(meta["input"] ?? "?")\n" + (tail.isEmpty ? "(no thermo yet)" : tail)
                 + (s.isTerminal ? "\nfetch_job downloads results" : "")
        }
        let elapsed = (meta["started"] as? Double)
            .map { String(format: "%.0f s", Date().timeIntervalSince1970 - $0) } ?? "?"
        let where_ = (meta["host"] as? String).map { " · host \($0)" } ?? ""
        return """
        \(id): \(Jobs.state(id))  (elapsed \(elapsed), \(meta["threads"] ?? "?") threads\(where_))
        input: \(meta["input"] ?? "?")
        \(Jobs.progress(id))
        """

    case "job_log":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        let n = a["lines"] as? Int ?? 40
        if HostedClient.cloudMeta(id) != nil {
            let local = Jobs.dir(id).appendingPathComponent("log.lammps")
            if let text = try? String(contentsOf: local, encoding: .utf8) {   // fetched already
                return text.split(separator: "\n").suffix(n).joined(separator: "\n")
            }
            let s = try HostedClient.fromSavedCredentials().status(id)
            return (s.thermo_tail ?? ["(no thermo yet)"]).joined(separator: "\n") + "\n(live tail from the endpoint; the full log arrives with fetch_job)"
        }
        if let h = Jobs.remoteHost(id) { return RemoteJobs.logTail(id, host: h, lines: n) }
        let log = Jobs.dir(id).appendingPathComponent("log.lammps")
        let alt = Jobs.dir(id).appendingPathComponent("stdout.log")
        guard let text = (try? String(contentsOf: log, encoding: .utf8))
                      ?? (try? String(contentsOf: alt, encoding: .utf8)) else {
            throw err("no log yet for \(id)")
        }
        return text.split(separator: "\n").suffix(n).joined(separator: "\n")

    case "list_jobs":
        return Jobs.list()

    case "job_files":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        guard let meta = Jobs.meta(id) else { throw err("unknown job \(id)") }
        func listing(_ dir: String, label: String) -> String {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: dir), !names.isEmpty else {
                return "\(label): (empty)"
            }
            let rows = names.sorted().prefix(200).map { name -> String in
                let size = ((try? fm.attributesOfItem(atPath: dir + "/" + name))?[.size] as? Int) ?? 0
                return "  \(name)  \(size) bytes"
            }
            return "\(label): \(dir)\n" + rows.joined(separator: "\n")
        }
        if HostedClient.cloudMeta(id) != nil {
            let res = Jobs.dir(id).appendingPathComponent("results").path
            return listing(res, label: "fetched results") + "\n" + listing(Jobs.dir(id).path, label: "job bookkeeping")
                 + (FileManager.default.fileExists(atPath: res) ? "" : "\n(hosted job — fetch_job downloads results when done)")
        }
        if let h = Jobs.remoteHost(id) {
            return RemoteJobs.files(id, host: h) + "\n"
                 + listing(Jobs.dir(id).path, label: "local job bookkeeping")
                 + "\n(use fetch_job to pull the remote run directory here)"
        }
        let cwd = meta["cwd"] as? String ?? "?"
        return listing(cwd, label: "run directory") + "\n"
             + listing(Jobs.dir(id).path, label: "job bookkeeping")

    case "cancel_job":
        guard let id = a["job_id"] as? String else { throw err("invalid arguments: job_id") }
        if HostedClient.cloudMeta(id) != nil { return try HostedClient.fromSavedCredentials().cancel(id).summary }
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
                   "serverInfo": ["name": "mdengine", "version": "0.7.1"]])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": toolList])
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
