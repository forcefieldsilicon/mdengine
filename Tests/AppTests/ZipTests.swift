import XCTest
@testable import LAMMPSCore

/// The pure-Swift zip writer that replaced /usr/bin/zip (GJOB-164).
final class ZipTests: XCTestCase {
    func testRoundTripThroughSystemUnzip() throws {
        let text = String(repeating: "MDEngine zip writer — deflate me. ", count: 400)
        let entries = [
            Zip.Entry(path: "[Content_Types].xml", text: "<Types/>"),
            Zip.Entry(path: "dir/nested/data.bin", data: Data((0..<2048).map { UInt8($0 & 0xFF) }), deflate: false),
            Zip.Entry(path: "text/long.txt", text: text),
            Zip.Entry(path: "empty.txt", data: Data()),
        ]
        let zip = try Zip.archive(entries)
        XCTAssertEqual(zip.prefix(2), Data([0x50, 0x4B]))
        XCTAssertEqual(try Zip.entryNames(zip), entries.map(\.path))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.zip")
        try zip.write(to: url)

        // The reference reader accepts it (CRC + sizes + structure) …
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-tqq", url.path]
        test.standardOutput = Pipe(); test.standardError = Pipe()
        try test.run(); test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0, "unzip -t rejected the archive")

        // … and extracts byte-identical content, including the deflated part.
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-qq", url.path, "-d", dir.appendingPathComponent("out").path]
        try extract.run(); extract.waitUntilExit()
        XCTAssertEqual(extract.terminationStatus, 0)
        for e in entries {
            let got = try Data(contentsOf: dir.appendingPathComponent("out").appendingPathComponent(e.path))
            XCTAssertEqual(got, e.data, e.path)
        }
    }

    func testDeflateIsUsedWhenItHelps() throws {
        let compressible = Zip.Entry(path: "a.txt", text: String(repeating: "abcabcabc", count: 1000))
        let zip = try Zip.archive([compressible])
        XCTAssertLessThan(zip.count, compressible.data.count / 4)
        // method field of the local header (offset 8) = 8 (deflate)
        XCTAssertEqual(Int(zip[8]) | Int(zip[9]) << 8, 8)
        // incompressible data is stored (method 0) rather than grown
        let noise = Zip.Entry(path: "n.bin", data: Data((0..<4096).map { _ in UInt8.random(in: 0...255) }))
        let z2 = try Zip.archive([noise])
        XCTAssertEqual(Int(z2[8]) | Int(z2[9]) << 8, 0)
        XCTAssertLessThan(z2.count, noise.data.count + 200)
    }

    func testDosDateTime() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 9; c.hour = 1; c.minute = 2; c.second = 30
        c.timeZone = TimeZone.current
        let d = Calendar(identifier: .gregorian).date(from: c)!
        let (t, day) = Zip.dosDateTime(d)
        XCTAssertEqual(Int(day), (2026 - 1980) << 9 | 9 << 5 | 9)
        XCTAssertEqual(Int(t), 1 << 11 | 2 << 5 | 15)
    }
}
