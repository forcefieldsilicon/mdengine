import XCTest
@testable import LAMMPSCore

/// Offline pieces of the hosted-tier client. The wire protocol itself is exercised
/// against hosted/mock/mock_endpoint.py (see hosted/README.md), not here.
final class HostedClientTests: XCTestCase {
    func testDeckTarExcludesArtifacts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mde-deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("results"), withIntermediateDirectories: true)
        for name in ["in.lmp", "ffield.reax.X", "O2.data", "big.traj", "old.lammpstrj", "run.log", "sim.ckpt.a", "results/traj.lammpstrj"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let tarball = try HostedClient.tarDeck(dir)
        let list = try HostedClient.run("/usr/bin/tar", ["-tzf", "-"], stdin: tarball)
        let names = Set(String(decoding: list.out, as: UTF8.self).split(separator: "\n").map { $0.replacingOccurrences(of: "./", with: "") })
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
