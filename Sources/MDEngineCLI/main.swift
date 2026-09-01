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
  mdengine decimate <file> --every N [-o out.xyz] [--charges]
                                           keep every Nth frame (last always kept)
  mdengine run <input> [--threads N] [--lmp PATH] [--log FILE]
                                           run LAMMPS with -sf omp -pk omp N
  mdengine gui                             open MDEngine.app

NOTES
  Trajectories are XYZ / extended-XYZ or native LAMMPS dump (ITEM: TIMESTEP).
  --elements maps numeric type tokens to symbols by position: --elements O,Al
  labels type 1 as O and type 2 as Al.
  Rows with non-finite (NaN/inf) coordinates are dropped. Safe on in-flight
  dumps: a file still being written parses to its complete frames.
  Every subcommand accepts -h/--help.
  `run` finds LAMMPS via $MDENGINE_LMP, then lmp_mpi / lmp_serial / lmp on PATH.
  Default --threads = number of performance cores.
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
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
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
