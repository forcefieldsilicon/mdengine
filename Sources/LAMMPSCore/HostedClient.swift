import Foundation

// Hosted accelerated runs — the client side of hosted/CONTRACT.md (GJOB-091).
//
// This is a TRANSPORT, not a product: the same job model as the local runner
// and the ssh remote hosts (`~/.mdengine/jobs/<id>/` bookkeeping, deck dir
// shipped whole, results pulled back), the difference being that the deck runs
// on a rented GPU behind api.forcefieldsilicon.com and debits a prepaid credit
// balance. One client, three surfaces: `mdengine run --gpu`, MCP
// `submit_lammps host=cloud`, and the app's File ▸ Run Accelerated….
//
// Credentials: $MDENGINE_API_KEY, else ~/.mdengine/credentials (JSON, mode 0600):
//   { "api_key": "mde_…", "endpoint": "http://127.0.0.1:8787/v1" }   // endpoint optional
// $MDENGINE_HOSTED_URL overrides the endpoint (how the mock is reached in dev).

public struct HostedCredentials: Codable, Equatable {
    public var apiKey: String
    public var endpoint: String?

    public init(apiKey: String, endpoint: String? = nil) {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    public static let productionEndpoint = "https://api.forcefieldsilicon.com/v1"
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mdengine/credentials")

    /// Env first (CI, one-off shells), then the credentials file.
    public static func load() -> HostedCredentials? {
        let env = ProcessInfo.processInfo.environment
        var creds: HostedCredentials?
        if let data = try? Data(contentsOf: fileURL),
           let c = try? JSONDecoder().decode(HostedCredentials.self, from: data) {
            creds = c
        }
        if let k = env["MDENGINE_API_KEY"], !k.isEmpty {
            creds = HostedCredentials(apiKey: k, endpoint: creds?.endpoint)
        }
        if let u = env["MDENGINE_HOSTED_URL"], !u.isEmpty, creds != nil {
            creds?.endpoint = u
        }
        return creds
    }

    /// Written 0600: the key is money.
    public func save() throws {
        let dir = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public var resolvedEndpoint: String {
        ProcessInfo.processInfo.environment["MDENGINE_HOSTED_URL"] ?? endpoint ?? Self.productionEndpoint
    }
}

// MARK: - Wire types (hosted/CONTRACT.md)

public struct HostedAccount: Codable {
    public let balance_usd: Double
    public let rate_table: [String: Double]
    public let keys_created: String?
}

public struct HostedJobSpec: Codable {
    public var input: String
    public var label: String?
    public var gpu: String
    public var wall_limit_s: Int
    public var estimate_s: Int
    public var launch: String

    public init(input: String, label: String? = nil, gpu: String = "any",
                wallLimitS: Int = 14400, estimateS: Int = 3600, launch: String = "default") {
        self.input = input; self.label = label; self.gpu = gpu
        self.wall_limit_s = wallLimitS; self.estimate_s = estimateS; self.launch = launch
    }
}

public struct HostedJobStatus: Codable {
    public let id: String
    public let state: String
    public let created: String?
    public let started: String?
    public let finished: String?
    public let gpu: String?
    public let rate_usd_per_h: Double?
    public let billed_s: Int?
    public let cost_usd: Double?
    public let thermo_tail: [String]?
    public let exitcode: Int?
    public let error: String?
    public let attempt: Int?

    public var isTerminal: Bool { ["done", "failed", "cancelled"].contains(state) }

    /// One line, the way job_status prints local jobs.
    public var summary: String {
        var s = "\(id): \(state)"
        if let g = gpu, state != "created", state != "uploaded" { s += " on \(g)" }
        if let c = cost_usd, c > 0 { s += String(format: "  $%.4f", c) }
        if let b = billed_s, b > 0 { s += " (\(b) s billed)" }
        if let e = error { s += "  error: \(e)" }
        if let x = exitcode, isTerminal { s += "  exit \(x)" }
        return s
    }
}

public struct HostedError: LocalizedError {
    public let message: String
    public let status: Int?
    public var errorDescription: String? { message }
    init(_ m: String, status: Int? = nil) { message = m; self.status = status }
}

// MARK: - Client

public final class HostedClient {
    public let creds: HostedCredentials
    public let base: URL
    private let session: URLSession

    /// Big artifacts a deck directory accumulates; never worth uploading (same list as RemoteHost).
    public static let deckExcludes = ["*.traj", "*.lammpstrj", "*.dump", "*.ckpt*", "*.restart*",
                                      "*.log", "*.mp4", "*.gif", "*.xlsx", ".git", ".DS_Store", "results", "results-*"]

    public init(credentials: HostedCredentials) throws {
        guard let u = URL(string: credentials.resolvedEndpoint) else {
            throw HostedError("bad endpoint URL: \(credentials.resolvedEndpoint)")
        }
        creds = credentials
        base = u
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600     // deck uploads / result downloads can be large
        session = URLSession(configuration: cfg)
    }

    /// Convenience: fail with a message that says how to log in.
    public static func fromSavedCredentials() throws -> HostedClient {
        guard let c = HostedCredentials.load() else {
            throw HostedError("no API key — run `mdengine login <mde_key>` (or set $MDENGINE_API_KEY). "
                            + "Keys come with a credit pack: https://forcefieldsilicon.com/mdengine")
        }
        return try HostedClient(credentials: c)
    }

    // MARK: HTTP (synchronous — CLI and MCP are single-threaded; the app calls off-main)

    private func request(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil,
                         absolute: URL? = nil, auth: Bool = true) throws -> (Int, Data) {
        let url = absolute ?? base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        if auth { req.setValue("Bearer \(creds.apiKey)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            req.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, Data)?
        var failure: Error?
        session.dataTask(with: req) { data, resp, error in
            if let error { failure = error }
            else { out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        if let failure {
            throw HostedError("cannot reach \(url.host ?? url.absoluteString): \(failure.localizedDescription)")
        }
        return out!
    }

    private func decode<T: Decodable>(_ type: T.Type, _ r: (Int, Data), expect: Set<Int> = [200, 201, 202]) throws -> T {
        guard expect.contains(r.0) else { throw serverError(r) }
        do { return try JSONDecoder().decode(type, from: r.1) }
        catch { throw HostedError("unexpected response from \(base.host ?? "endpoint") (HTTP \(r.0)): \(String(decoding: r.1.prefix(200), as: UTF8.self))") }
    }

    private func serverError(_ r: (Int, Data)) -> HostedError {
        let msg = (try? JSONSerialization.jsonObject(with: r.1) as? [String: Any])?["error"] as? String
        switch r.0 {
        case 401: return HostedError("API key rejected (HTTP 401) — check `mdengine login`", status: 401)
        case 402: return HostedError("insufficient credit balance (HTTP 402) — buy credits at https://forcefieldsilicon.com/mdengine", status: 402)
        default:  return HostedError("endpoint error HTTP \(r.0)\(msg.map { ": \($0)" } ?? "")", status: r.0)
        }
    }

    // MARK: API

    public func me() throws -> HostedAccount {
        try decode(HostedAccount.self, request("GET", "me"))
    }

    public func status(_ id: String) throws -> HostedJobStatus {
        try decode(HostedJobStatus.self, request("GET", "jobs/\(id)"))
    }

    public func list() throws -> [HostedJobStatus] {
        struct L: Codable { let jobs: [HostedJobStatus] }
        return try decode(L.self, request("GET", "jobs")).jobs
    }

    public func cancel(_ id: String) throws -> HostedJobStatus {
        try decode(HostedJobStatus.self, request("DELETE", "jobs/\(id)"))
    }

    /// Tar the deck's directory (minus trajectories/checkpoints/logs), create the job,
    /// upload, start. Returns the endpoint's job id and writes local bookkeeping so
    /// job_status / list_jobs / fetch see it like any other job.
    public func submit(input: String, spec: HostedJobSpec? = nil) throws -> String {
        let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw HostedError("no such input: \(input)") }
        let deckDir = inputURL.deletingLastPathComponent()
        var spec = spec ?? HostedJobSpec(input: inputURL.lastPathComponent)
        spec.input = inputURL.lastPathComponent
        if spec.label == nil { spec.label = inputURL.deletingPathExtension().lastPathComponent }
        // Dev only: the mock's "pod" is this Mac's lmp_serial, which has no KOKKOS — let the
        // launch line be overridden without touching any surface's code path.
        if let l = ProcessInfo.processInfo.environment["MDENGINE_HOSTED_LAUNCH"], !l.isEmpty { spec.launch = l }

        let tarball = try Self.tarDeck(deckDir)
        guard tarball.count <= 2_000_000_000 else {
            throw HostedError("deck directory tars to \(tarball.count / 1_000_000) MB — the limit is 2 GB; move old results out of it")
        }

        struct Created: Codable { let id: String; let upload_url: String }
        let specObj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec))
        let created = try decode(Created.self, request("POST", "jobs", json: specObj))
        guard let up = URL(string: created.upload_url) else { throw HostedError("bad upload_url from endpoint") }
        let put = try request("PUT", "", body: tarball, absolute: up, auth: false)
        guard (200..<300).contains(put.0) else { throw HostedError("deck upload failed (HTTP \(put.0))") }
        _ = try decode(HostedJobStatus.self, request("POST", "jobs/\(created.id)/start"))

        let jobDir = Self.jobsRoot.appendingPathComponent(created.id)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "id": created.id, "input": inputURL.path, "cwd": deckDir.path,
            "cloud": true, "endpoint": base.absoluteString, "gpu": spec.gpu, "label": spec.label ?? "",
            "started": Date().timeIntervalSince1970, "deck_bytes": tarball.count,
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
            .write(to: jobDir.appendingPathComponent("job.json"))
        return created.id
    }

    /// Download the results tarball (work/ + log.lammps + exitcode) into
    /// ~/.mdengine/jobs/<id>/results/ and mirror log/exitcode into the job dir.
    /// Returns the results directory.
    @discardableResult
    public func fetch(_ id: String) throws -> URL {
        struct R: Codable { let download_url: String; let bytes: Int? }
        let r = try decode(R.self, request("GET", "jobs/\(id)/results"), expect: [200])
        guard let dl = URL(string: r.download_url) else { throw HostedError("bad download_url from endpoint") }
        let got = try request("GET", "", absolute: dl, auth: false)
        guard got.0 == 200, !got.1.isEmpty else { throw HostedError("results download failed (HTTP \(got.0))") }

        let jobDir = Self.jobsRoot.appendingPathComponent(id)
        let results = jobDir.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let tmp = jobDir.appendingPathComponent("results.tar.gz")
        try got.1.write(to: tmp)
        let untar = try Self.run("/usr/bin/tar", ["-xzf", tmp.path, "-C", results.path])
        guard untar.status == 0 else { throw HostedError("untar failed: \(untar.err)") }
        try? FileManager.default.removeItem(at: tmp)
        // The runner tars `work/ log.lammps exitcode` at the top level; surface the two
        // bookkeeping files where local jobs keep them.
        for name in ["log.lammps", "exitcode", "stdout.txt"] {
            let src = results.appendingPathComponent(name), dst = jobDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
        return results
    }

    /// Poll until terminal, reporting each status change (and new thermo lines) to `progress`.
    public func wait(_ id: String, every seconds: Double = 5,
                     progress: ((HostedJobStatus, [String]) -> Void)? = nil) throws -> HostedJobStatus {
        var seenTail: [String] = []
        var lastState = ""
        while true {
            let s = try status(id)
            let tail = s.thermo_tail ?? []
            let fresh = tail.filter { !seenTail.contains($0) }
            if s.state != lastState || !fresh.isEmpty { progress?(s, fresh) }
            seenTail = tail; lastState = s.state
            if s.isTerminal { return s }
            Thread.sleep(forTimeInterval: seconds)
        }
    }

    // MARK: helpers

    public static let jobsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mdengine/jobs")

    /// job.json for a cloud job, if this id is one.
    public static func cloudMeta(_ id: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: jobsRoot.appendingPathComponent(id).appendingPathComponent("job.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["cloud"] as? Bool == true else { return nil }
        return obj
    }

    /// The trajectory worth opening from a results dir: newest of the dump-like files.
    public static func primaryTrajectory(in results: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: results, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let exts: Set<String> = ["traj", "lammpstrj", "xyz", "dump"]
        var best: (URL, Int)?
        for case let u as URL in e where exts.contains(u.pathExtension.lowercased()) {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if best == nil || size > best!.1 { best = (u, size) }
        }
        return best?.0
    }

    static func tarDeck(_ dir: URL) throws -> Data {
        var args = ["-czf", "-", "-C", dir.path]
        for x in deckExcludes { args += ["--exclude", x] }
        args.append(".")
        let r = try run("/usr/bin/tar", args)
        guard r.status == 0 else { throw HostedError("tar of \(dir.path) failed: \(r.err)") }
        return r.out
    }

    struct Shell { let status: Int32; let out: Data; let err: String }
    static func run(_ exe: String, _ args: [String], stdin: Data? = nil) throws -> Shell {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        let i = stdin.map { _ in Pipe() }
        if let i { p.standardInput = i }
        try p.run()
        if let i, let stdin {
            DispatchQueue.global().async {     // feed concurrently with the drain below: no pipe deadlock either way
                i.fileHandleForWriting.write(stdin)
                i.fileHandleForWriting.closeFile()
            }
        }
        // Drain stdout before waiting: a multi-MB tarball would fill the pipe and deadlock.
        let out = o.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return Shell(status: p.terminationStatus, out: out, err: err)
    }
}
