import Foundation

// Remote execution for the job runner — the transport under the hosted / BYO-box
// tier. Same tool contract as local jobs (submit → job_status / job_log /
// job_files / cancel_job); the difference is WHERE the deck runs.
//
// Hosts are declared in ~/.mdengine/hosts.json:
//
//   {
//     "default": "gpu1",
//     "hosts": {
//       "gpu1": {
//         "ssh": "arvand@gpu1.example.net",          // anything `ssh` accepts (alias, user@host)
//         "ssh_options": ["-p", "22"],                 // optional extra ssh/rsync -e flags
//         "workdir": "~/mdengine-jobs",                // remote base dir; ~ = remote $HOME
//         "lmp": "/usr/local/bin/lmp",                 // remote LAMMPS binary (PATH is NOT trusted over ssh)
//         "threads": 8,                                // default threads for this host
//         "launch": "{lmp} -in {input} -sf omp -pk omp {threads} -log {log}",   // optional template
//         "potentials": "/usr/local/share/lammps/potentials",                  // optional LAMMPS_POTENTIALS
//         "excludes": ["*.traj", "*.lammpstrj"]        // optional extra rsync excludes for the deck dir
//       }
//     }
//   }
//
// A GPU host differs only in its launch template, e.g.
//   "launch": "{lmp} -in {input} -k on g 1 -sf kk -pk kokkos newton on neigh half -log {log}"
//
// Remote job layout: <workdir>/<id>/work/ (the deck's directory, rsynced),
// plus <workdir>/<id>/{log.lammps,stdout.log,exitcode,pid}. The job is
// launched under nohup with its exit code written remotely, so it survives
// the ssh session, this server, and this Mac going to sleep.

struct RemoteHost {
    let name: String
    let ssh: String
    let sshOptions: [String]
    let workdir: String
    let lmp: String
    let threads: Int?
    let launch: String
    let potentials: String?
    let excludes: [String]

    static let defaultLaunch = "{lmp} -in {input} -sf omp -pk omp {threads} -log {log}"
    /// Big artifacts a deck directory typically accumulates; never worth shipping up.
    static let defaultExcludes = ["*.traj", "*.lammpstrj", "*.dump", "*.ckpt*", "*.restart*",
                                  "*.log", "*.mp4", "*.gif", "*.xlsx", ".git", ".DS_Store"]

    init(name: String, json: [String: Any]) throws {
        guard let ssh = json["ssh"] as? String, !ssh.isEmpty else { throw err("host \(name): missing \"ssh\"") }
        guard let lmp = json["lmp"] as? String, !lmp.isEmpty else { throw err("host \(name): missing \"lmp\" (remote LAMMPS path)") }
        self.name = name
        self.ssh = ssh
        self.sshOptions = json["ssh_options"] as? [String] ?? []
        self.workdir = json["workdir"] as? String ?? "~/mdengine-jobs"
        self.lmp = lmp
        self.threads = json["threads"] as? Int
        self.launch = json["launch"] as? String ?? Self.defaultLaunch
        self.potentials = json["potentials"] as? String
        self.excludes = Self.defaultExcludes + (json["excludes"] as? [String] ?? [])
    }

    /// Remote job dir as a shell expression (tilde → remote $HOME, safely quoted otherwise).
    func jobDirExpr(_ id: String) -> String {
        let base: String
        if workdir == "~" { base = "\"$HOME\"" }
        else if workdir.hasPrefix("~/") { base = "\"$HOME\"/" + shellQuote(String(workdir.dropFirst(2))) }
        else { base = shellQuote(workdir) }
        return base + "/" + shellQuote(id)
    }

    /// rsync destination for the deck dir (tilde is expanded by the remote shell).
    func rsyncDest(_ id: String) -> String {
        "\(ssh):\(workdir)/\(id)/work/"
    }

    /// The launch line run inside <job>/work/ on the remote host.
    func launchCommand(input: String, threads: Int) -> String {
        launch.replacingOccurrences(of: "{lmp}", with: shellQuote(lmp))
              .replacingOccurrences(of: "{input}", with: shellQuote(input))
              .replacingOccurrences(of: "{threads}", with: "\(threads)")
              .replacingOccurrences(of: "{log}", with: "../log.lammps")
    }

    /// Script the remote `bash -s` runs to start the job. Prints the wrapper pid.
    func launchScript(id: String, input: String, threads: Int) -> String {
        var env = "OMP_NUM_THREADS=\(threads)"
        if let p = potentials { env += " LAMMPS_POTENTIALS=\(shellQuote(p))" }
        let cmd = launchCommand(input: input, threads: threads)
        return """
        set -e
        JOB=\(jobDirExpr(id))
        mkdir -p "$JOB/work"
        cd "$JOB/work"
        nohup sh -c \(shellQuote("\(env) \(cmd) > ../stdout.log 2>&1; echo $? > ../exitcode")) >/dev/null 2>&1 &
        echo $! > "$JOB/pid"
        cat "$JOB/pid"
        """
    }
}

enum RemoteHosts {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mdengine/hosts.json")

    static func load() throws -> (defaultHost: String?, hosts: [String: RemoteHost]) {
        guard let data = try? Data(contentsOf: configURL) else { return (nil, [:]) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw err("\(configURL.path): not a JSON object")
        }
        var hosts: [String: RemoteHost] = [:]
        for (name, v) in obj["hosts"] as? [String: Any] ?? [:] {
            guard let dict = v as? [String: Any] else { throw err("host \(name): not an object") }
            hosts[name] = try RemoteHost(name: name, json: dict)
        }
        return (obj["default"] as? String, hosts)
    }

    static func resolve(_ name: String?) throws -> RemoteHost? {
        let (def, hosts) = try load()
        guard let wanted = name ?? def, wanted != "local" else { return nil }
        guard let h = hosts[wanted] else {
            let known = hosts.keys.sorted().joined(separator: ", ")
            throw err("unknown host \"\(wanted)\" — configured: \(known.isEmpty ? "(none; see ~/.mdengine/hosts.json)" : known)")
        }
        return h
    }

    static func describe() -> String {
        do {
            let (def, hosts) = try load()
            if hosts.isEmpty { return "no remote hosts configured (\(configURL.path))\nlocal execution only" }
            return hosts.keys.sorted().map { name in
                let h = hosts[name]!
                let tag = name == def ? "  (default)" : ""
                return "\(name)\(tag): ssh \(h.ssh), lmp \(h.lmp), workdir \(h.workdir), threads \(h.threads.map(String.init) ?? "auto")\n  launch: \(h.launch)"
            }.joined(separator: "\n") + "\nlocal: this machine (use host \"local\" to force)"
        } catch {
            return "hosts.json error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Running ssh / rsync

struct ShellResult { let status: Int32; let out: String; let errText: String }

@discardableResult
func runCapture(_ exe: String, _ args: [String], stdin: String? = nil) throws -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    if let stdin {
        let i = Pipe(); p.standardInput = i
        try p.run()
        i.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        i.fileHandleForWriting.closeFile()
    } else {
        try p.run()
    }
    let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errText = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return ShellResult(status: p.terminationStatus, out: out, errText: errText)
}

extension RemoteHost {
    var sshBase: [String] { ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"] + sshOptions }

    func ssh(_ script: String) throws -> ShellResult {
        try runCapture("/usr/bin/ssh", sshBase + [ssh, "bash -s"], stdin: script)
    }

    func rsync(_ args: [String]) throws -> ShellResult {
        let e = (["ssh"] + sshBase).joined(separator: " ")
        return try runCapture("/usr/bin/rsync", ["-az", "-e", e] + args)
    }
}

// MARK: - Remote job operations (called from Jobs when job.json carries "host")

enum RemoteJobs {
    static func submit(host: RemoteHost, input: String, threads: Int?, label: String?) throws -> String {
        let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw err("no such input: \(input)") }
        let deckDir = inputURL.deletingLastPathComponent()
        let nthreads = threads ?? host.threads ?? 4

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let slug = (label ?? inputURL.deletingPathExtension().lastPathComponent)
            .lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
        let id = "MDJOB-\(stamp).\(slug)"
        let jobDir = Jobs.dir(id)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

        // 1. remote job dir
        let mk = try host.ssh("mkdir -p \(host.jobDirExpr(id))/work && echo ok")
        guard mk.status == 0 else { throw err("ssh \(host.ssh) failed: \(mk.errText.trimmingCharacters(in: .whitespacesAndNewlines))") }

        // 2. ship the deck directory (minus trajectories/checkpoints/logs)
        var rs = ["--delete"]
        for x in host.excludes { rs += ["--exclude", x] }
        rs += [deckDir.path + "/", host.rsyncDest(id)]
        let up = try host.rsync(rs)
        guard up.status == 0 else { throw err("rsync to \(host.ssh) failed: \(up.errText.trimmingCharacters(in: .whitespacesAndNewlines))") }

        // 3. launch detached, capture the wrapper pid
        let launch = try host.ssh(host.launchScript(id: id, input: inputURL.lastPathComponent, threads: nthreads))
        guard launch.status == 0, let pid = Int(launch.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw err("remote launch failed: \(launch.errText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let metaObj: [String: Any] = [
            "id": id, "input": inputURL.path, "threads": nthreads, "lmp": host.lmp,
            "host": host.name, "ssh": host.ssh, "remote_dir": "\(host.workdir)/\(id)",
            "remote_pid": pid, "started": Date().timeIntervalSince1970,
            "cwd": deckDir.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: metaObj, options: [.prettyPrinted])
        try data.write(to: jobDir.appendingPathComponent("job.json"))
        return id
    }

    /// running | done (exit N) | FAILED (exit N) | vanished | unreachable
    static func state(_ id: String, host: RemoteHost) -> String {
        let script = """
        JOB=\(host.jobDirExpr(id))
        if [ -f "$JOB/exitcode" ]; then echo "EXIT $(cat "$JOB/exitcode")";
        elif [ -f "$JOB/cancelled" ]; then echo CANCELLED;
        elif [ -f "$JOB/pid" ] && kill -0 "$(cat "$JOB/pid")" 2>/dev/null; then echo RUNNING;
        else echo VANISHED; fi
        """
        guard let r = try? host.ssh(script), r.status == 0 else { return "unreachable (\(host.ssh))" }
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("EXIT ") {
            let code = s.dropFirst(5)
            return code == "0" ? "done (exit 0) on \(host.name)" : "FAILED (exit \(code)) on \(host.name)"
        }
        if s == "CANCELLED" { return "cancelled on \(host.name)" }
        return s == "RUNNING" ? "running on \(host.name)" : "vanished on \(host.name) (no exit code, process gone)"
    }

    static func logTail(_ id: String, host: RemoteHost, lines: Int) -> String {
        let script = """
        JOB=\(host.jobDirExpr(id))
        if [ -f "$JOB/log.lammps" ]; then tail -n \(lines) "$JOB/log.lammps";
        elif [ -f "$JOB/stdout.log" ]; then tail -n \(lines) "$JOB/stdout.log";
        else echo "(no log yet)"; fi
        """
        guard let r = try? host.ssh(script), r.status == 0 else { return "(unreachable: \(host.ssh))" }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func files(_ id: String, host: RemoteHost) -> String {
        let script = """
        JOB=\(host.jobDirExpr(id))
        echo "remote run directory: $JOB/work"; ls -la "$JOB/work" 2>/dev/null | tail -n +2
        echo "remote bookkeeping: $JOB"; ls -la "$JOB" 2>/dev/null | grep -v ' work$' | tail -n +2
        """
        guard let r = try? host.ssh(script), r.status == 0 else { return "(unreachable: \(host.ssh))" }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull the remote run directory + logs into the local job dir (results/).
    static func fetch(_ id: String, host: RemoteHost, excludes: [String]) throws -> String {
        let local = Jobs.dir(id).appendingPathComponent("results")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        var args: [String] = []
        for x in excludes { args += ["--exclude", x] }
        args += ["\(host.ssh):\(host.workdir)/\(id)/work/", local.path + "/"]
        let r1 = try host.rsync(args)
        guard r1.status == 0 else { throw err("rsync from \(host.ssh) failed: \(r1.errText)") }
        let r2 = try host.rsync(["\(host.ssh):\(host.workdir)/\(id)/log.lammps",
                                 "\(host.ssh):\(host.workdir)/\(id)/stdout.log", Jobs.dir(id).path + "/"])
        _ = r2
        let names = (try? FileManager.default.contentsOfDirectory(atPath: local.path))?.sorted() ?? []
        return "fetched \(names.count) files → \(local.path)\n" + names.prefix(50).map { "  " + $0 }.joined(separator: "\n")
    }

    static func cancel(_ id: String, host: RemoteHost) -> String {
        let script = """
        JOB=\(host.jobDirExpr(id))
        [ -f "$JOB/pid" ] || { echo "no pid recorded"; exit 0; }
        P=$(cat "$JOB/pid")
        pkill -TERM -P "$P" 2>/dev/null; kill -TERM "$P" 2>/dev/null && echo "sent SIGTERM to $P" || echo "process already gone"
        [ -f "$JOB/exitcode" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$JOB/cancelled"
        """
        guard let r = try? host.ssh(script), r.status == 0 else { return "\(id): unreachable (\(host.ssh))" }
        return "\(id): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
