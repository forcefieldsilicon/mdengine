import XCTest
@testable import LAMMPSCore

/// Offline pieces of the hosted-tier client. The wire protocol itself is exercised
/// against hosted/mock/mock_endpoint.py (see hosted/README.md), not here.
final class HostedClientTests: XCTestCase {
    /// `tar -tzf -` over a tarball we produced. Process in a test on macOS is fine; the shipping code is
    /// what must not spawn anything.
    static func tarList(_ tarball: Data) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-tzf", "-"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = Pipe()
        try p.run()
        DispatchQueue.global().async {
            stdin.fileHandleForWriting.write(tarball)
            stdin.fileHandleForWriting.closeFile()
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "real tar could not list our deck tarball")
        return String(decoding: out, as: UTF8.self)
    }

    func testDeckTarExcludesArtifacts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mde-deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("results"), withIntermediateDirectories: true)
        for name in ["in.lmp", "ffield.reax.X", "O2.data", "big.traj", "old.lammpstrj", "run.log", "sim.ckpt.a", "results/traj.lammpstrj"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let tarball = try HostedClient.tarDeck(dir)
        // Listed by REAL tar, not by our own reader: tarDeck stopped shelling out in GJOB-152, and the
        // thing worth checking is still that the endpoint's runner can read what we upload.
        let list = try Self.tarList(tarball)
        let names = Set(list.split(separator: "\n").map { $0.replacingOccurrences(of: "./", with: "") })
        XCTAssertTrue(names.isSuperset(of: ["in.lmp", "ffield.reax.X", "O2.data"]))
        for excluded in ["big.traj", "old.lammpstrj", "run.log", "sim.ckpt.a", "results/traj.lammpstrj"] {
            XCTAssertFalse(names.contains(excluded), "\(excluded) should not be uploaded")
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func testPrimaryTrajectoryPicksLargestDumpLikeFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mde-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try String(repeating: "a", count: 10).write(to: dir.appendingPathComponent("small.xyz"), atomically: true, encoding: .utf8)
        try String(repeating: "a", count: 1000).write(to: dir.appendingPathComponent("traj.lammpstrj"), atomically: true, encoding: .utf8)
        try String(repeating: "a", count: 5000).write(to: dir.appendingPathComponent("log.lammps"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HostedClient.primaryTrajectory(in: dir)?.lastPathComponent, "traj.lammpstrj")
        try? FileManager.default.removeItem(at: dir)
    }

    func testJobStatusSummaryAndTerminal() throws {
        let json = """
        {"id":"MDJOB-20260905-K3F9QZ","state":"done","gpu":"rtx4090","rate_usd_per_h":2.0,"billed_s":812,"cost_usd":0.4511,"exitcode":0}
        """
        let s = try JSONDecoder().decode(HostedJobStatus.self, from: Data(json.utf8))
        XCTAssertTrue(s.isTerminal)
        XCTAssertEqual(s.summary, "MDJOB-20260905-K3F9QZ: done on rtx4090  $0.4511 (812 s billed)  exit 0")
        let q = try JSONDecoder().decode(HostedJobStatus.self, from: Data(#"{"id":"X","state":"queued","gpu":"any"}"#.utf8))
        XCTAssertFalse(q.isTerminal)
    }

    func testCredentialsEnvOverrideEndpoint() {
        let c = HostedCredentials(apiKey: "mde_abc", endpoint: nil)
        // No env in the test runner → production endpoint.
        if ProcessInfo.processInfo.environment["MDENGINE_HOSTED_URL"] == nil {
            XCTAssertEqual(c.resolvedEndpoint, HostedCredentials.productionEndpoint)
        }
        XCTAssertEqual(HostedCredentials(apiKey: "mde_abc", endpoint: "http://127.0.0.1:8787/v1").resolvedEndpoint,
                       ProcessInfo.processInfo.environment["MDENGINE_HOSTED_URL"] ?? "http://127.0.0.1:8787/v1")
    }
}
