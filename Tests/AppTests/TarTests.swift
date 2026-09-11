import XCTest
@testable import LAMMPSCore

/// Tar without /usr/bin/tar (GJOB-152).
///
/// The point of these tests is interoperability, not round-tripping with ourselves: a format only we can
/// read would be worse than the shell-out it replaces, because the endpoint's runner untars our uploads with
/// real GNU tar and our downloads come from real tar. So the two central tests hand our output to
/// /usr/bin/tar and read real tar's output with ours. Those two use Process deliberately — in a test, on
/// macOS, which is allowed; the shipping code is what must not.
final class TarTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tar-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ rel: String, _ contents: String) throws {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func sh(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit(); return p.terminationStatus
    }

    // MARK: the two that matter

    func testRealTarCanReadWhatWeWrite() throws {
        try write("in.lmp", "units lj\nrun 100\n")
        try write("data/Al.eam", "# potential\n1 2 3\n")
        try write("nested/deep/notes.txt", "hello")
        let gz = try Tar.archiveGzipped(directory: dir)

        let out = dir.deletingLastPathComponent().appendingPathComponent("out-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let gzURL = out.appendingPathComponent("a.tar.gz")
        try gz.write(to: gzURL)

        // The real thing, with the same flags the runner uses.
        XCTAssertEqual(try sh("/usr/bin/tar", ["-xzf", gzURL.path, "-C", out.path]), 0,
                       "/usr/bin/tar could not read our archive")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("in.lmp"), encoding: .utf8),
                       "units lj\nrun 100\n")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("data/Al.eam"), encoding: .utf8),
                       "# potential\n1 2 3\n")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("nested/deep/notes.txt"), encoding: .utf8),
                       "hello")
    }

    func testWeCanReadWhatRealTarWrites() throws {
        try write("log.lammps", "Step Temp\n0 300\n")
        try write("work/traj.xyz", "2\nframe\nAr 0 0 0\nAr 1 1 1\n")
        let gzURL = dir.deletingLastPathComponent().appendingPathComponent("real-" + UUID().uuidString + ".tar.gz")
        defer { try? FileManager.default.removeItem(at: gzURL) }
        XCTAssertEqual(try sh("/usr/bin/tar", ["-czf", gzURL.path, "-C", dir.path, "."]), 0)

        let dest = dir.deletingLastPathComponent().appendingPathComponent("x-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        let written = try Tar.extract(try Data(contentsOf: gzURL), to: dest)
        XCTAssertTrue(written.contains("log.lammps"), "got \(written)")
        XCTAssertTrue(written.contains("work/traj.xyz"), "got \(written)")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("log.lammps"), encoding: .utf8),
                       "Step Temp\n0 300\n")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("work/traj.xyz"), encoding: .utf8),
                       "2\nframe\nAr 0 0 0\nAr 1 1 1\n")
    }

    // MARK: gzip

    func testGzipRoundTripAndRealGunzip() throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })      // compressible but not trivially so
        let gz = try Tar.gzip(body)
        XCTAssertTrue(Tar.isGzip(gz))
        XCTAssertLessThan(gz.count, body.count)
        XCTAssertEqual(try Tar.gunzip(gz), body)

        // And real gunzip agrees, which is what proves the header/CRC/ISIZE framing is right rather than
        // merely self-consistent.
        let u = dir.appendingPathComponent("b.gz")
        try gz.write(to: u)
        XCTAssertEqual(try sh("/usr/bin/gunzip", ["-t", u.path]), 0, "real gunzip rejected our stream")
    }

    func testCorruptGzipIsRejectedNotSilentlyTruncated() throws {
        var gz = try Tar.gzip(Data("the quick brown fox".utf8))
        gz[gz.count - 5] ^= 0xFF                                    // damage the CRC region
        XCTAssertThrowsError(try Tar.gunzip(gz)) { e in
            XCTAssertTrue("\(e)".contains("CRC") || "\(e)".contains("DEFLATE"), "\(e)")
        }
        XCTAssertThrowsError(try Tar.gunzip(Data("not gzip at all".utf8)))
    }

    // MARK: excludes, determinism, safety

    func testExcludesMatchComponentsAndExtensionGlobs() throws {
        try write("in.lmp", "x")
        try write("big.lammpstrj", "trajectory")
        try write("results/keep.txt", "keep")
        try write(".git/config", "vcs")
        let entries = try Tar.entries(of: try Tar.archive(directory: dir, excluding: ["*.lammpstrj", ".git"]))
        let files = entries.filter { !$0.isDirectory }.map(\.path).sorted()
        XCTAssertEqual(files, ["in.lmp", "results/keep.txt"])
    }

    func testEveryDeckExcludePatternActuallyMatches() throws {
        // Regression on a bug in the first matcher: it understood *.ext and exact names only, so
        // *.ckpt*, *.restart* and results-* silently matched nothing and the excludes leaked checkpoints
        // into uploads. Drive the real HostedClient.deckExcludes list, not a convenient subset.
        try write("in.lmp", "keep")
        try write("Al.restart.5000", "restart")
        try write("run.ckpt.3", "checkpoint")
        try write("results-002/out.txt", "old results")
        try write("results/out.txt", "results")
        try write("traj.lammpstrj", "traj")
        try write("movie.mp4", "movie")
        try write(".git/config", "vcs")
        try write("sub/Cu.restart.1", "nested restart")
        let entries = try Tar.entries(of: try Tar.archive(directory: dir, excluding: HostedClient.deckExcludes))
        XCTAssertEqual(entries.filter { !$0.isDirectory }.map(\.path).sorted(), ["in.lmp"])
    }

    func testArchiveIsReproducible() throws {
        // Same deck, same bytes — otherwise hashing an upload to detect a changed deck is meaningless.
        try write("a.txt", "one")
        try write("b/c.txt", "two")
        XCTAssertEqual(try Tar.archive(directory: dir), try Tar.archive(directory: dir))
    }

    func testPathTraversalIsRefused() throws {
        // A malicious or buggy archive must not write outside the destination. Built by hand because real
        // tar refuses to create one.
        var evil = try Tar.header(name: "../escaped.txt", size: 5, type: "0", url: nil)
        evil.append(Data("pwned".utf8))
        evil.append(Data(count: Tar.blockSize - 5))
        evil.append(Data(count: Tar.blockSize * 2))
        let dest = dir.appendingPathComponent("dest")
        XCTAssertThrowsError(try Tar.extract(evil, to: dest)) { e in
            XCTAssertTrue("\(e)".contains("escapes"), "\(e)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("escaped.txt").path))
    }

    func testTooLongPathIsAnErrorNotATruncation() throws {
        let long = String(repeating: "d/", count: 60) + "f.txt"     // > 100 bytes
        XCTAssertThrowsError(try Tar.header(name: long, size: 0, type: "0", url: nil)) { e in
            XCTAssertTrue("\(e)".contains("too long"), "\(e)")
        }
    }

    func testEmptyDirectoryProducesAValidEmptyArchive() throws {
        let a = try Tar.archive(directory: dir)
        XCTAssertEqual(a.count, Tar.blockSize * 2)
        XCTAssertTrue(try Tar.entries(of: a).isEmpty)
    }

    // MARK: - the pure-Swift DEFLATE path (GJOB-190)
    //
    // The Linux CLI has no Compression framework, so Tar falls back to `storedDeflate`/`pureInflate` there.
    // Nothing on macOS exercises that path in production, which is exactly why it is tested here: both
    // directions are cross-checked against Apple's implementation, so a disagreement fails on this Mac
    // rather than silently corrupting a results download on a Linux box.

    func testPureInflateReadsWhatAppleCompressionDeflated() throws {
        // Compressible enough that Apple's encoder emits real Huffman blocks with back-references -- the
        // part of RFC 1951 that a stored-block-only decoder would not survive.
        let text = String(repeating: "run 5000\nthermo 100\nfix nvt all nvt temp 300 300 100\n", count: 400)
        let body = Data(text.utf8)
        let deflated = try Tar.deflate(body)
        XCTAssertLessThan(deflated.count, body.count / 4, "Apple's encoder should have actually compressed this")
        XCTAssertEqual(try Tar.pureInflate(deflated, hint: body.count), body)
    }

    func testAppleCompressionReadsWhatStoredDeflateWrote() throws {
        // Stored blocks are what the Linux CLI uploads inside its gzip framing; real gunzip (and the
        // endpoint's runner) must accept them, and Apple's inflate standing in for that is the cheap check.
        let body = Data((0..<200_000).map { (i: Int) -> UInt8 in UInt8((i * 31 + i / 97) % 256) })  // > 65535: multi-block
        let stored = Tar.storedDeflate(body)
        XCTAssertEqual(try Tar.inflate(stored, hint: body.count), body)
    }

    func testPureInflateRoundTripsStoredBlocksAtTheEdges() throws {
        // Empty and exactly-one-block inputs are where the block loop's final-flag maths goes wrong.
        for n in [0, 1, 65534, 65535, 65536] {
            let body = Data((0..<n).map { (i: Int) -> UInt8 in UInt8(i % 251) })
            XCTAssertEqual(try Tar.pureInflate(Tar.storedDeflate(body), hint: n), body, "n = \(n)")
        }
    }

    func testPureInflateReadsWhatRealGzipWrote() throws {
        // The load-bearing case: results tarballs are gzipped by GNU tar/zlib, whose dynamic-Huffman blocks
        // are what the Linux CLI actually has to decode. Apple's encoder is not a substitute for that here,
        // so this test compresses with the real /usr/bin/gzip and reads it back with the pure decoder.
        let text = String(repeating: "1 1 4.05 0.00 0.00 -3.36 12.7\n", count: 3000)
        let raw = Data(text.utf8)
        let plain = dir.appendingPathComponent("dump.lammpstrj")
        try raw.write(to: plain)
        XCTAssertEqual(try sh("/usr/bin/gzip", ["-9", plain.path]), 0)
        let gz = try Data(contentsOf: dir.appendingPathComponent("dump.lammpstrj.gz"))
        // gzip -9 on a plain file sets FNAME, so let gunzip's header parsing do the skipping -- but check the
        // pure inflate directly on the deflate body, since on macOS gunzip() would take the Apple path.
        var p = gz.startIndex + 10
        if gz[gz.startIndex + 3] & 0x08 != 0 { while gz[p] != 0 { p += 1 }; p += 1 }
        XCTAssertEqual(try Tar.pureInflate(Data(gz[p..<(gz.endIndex - 8)]), hint: raw.count), raw)
    }

    func testPureInflateRejectsGarbage() throws {
        // A corrupt download must throw, not return a plausible-looking prefix.
        XCTAssertThrowsError(try Tar.pureInflate(Data([0xff, 0xff, 0xff, 0xff]), hint: 16))
    }

    func testGzipOfARealArchiveInflatesWithBothPaths() throws {
        // End to end on the shape that actually crosses the wire: a tarred deck, gzipped, then read back by
        // the pure decoder after Apple's encoder made it.
        try write("in.deck", String(repeating: "pair_style eam/alloy\n", count: 500))
        try write("data/Al.data", String(repeating: "1 1 0.0 0.0 0.0\n", count: 2000))
        let raw = try Tar.archive(directory: dir)
        let gz = try Tar.gzip(raw)
        // Strip the 10-byte header and 8-byte trailer the way gunzip does, then inflate purely.
        let body = Data(gz[(gz.startIndex + 10)..<(gz.endIndex - 8)])
        let expanded = try Tar.pureInflate(body, hint: raw.count)
        XCTAssertEqual(expanded, raw)
        XCTAssertEqual(Tar.crc32(expanded), Tar.readLE32(gz, gz.endIndex - 8))
    }

    func testBinaryFileSurvivesExactly() throws {
        // Trajectories are not text; an off-by-one in the padding maths would corrupt them.
        let bytes = Data((0..<5000).map { UInt8(($0 * 7) % 256) })
        try bytes.write(to: dir.appendingPathComponent("frame.bin"))
        let dest = dir.appendingPathComponent("out")
        try Tar.extract(try Tar.archiveGzipped(directory: dir), to: dest)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("frame.bin")), bytes)
    }
}
