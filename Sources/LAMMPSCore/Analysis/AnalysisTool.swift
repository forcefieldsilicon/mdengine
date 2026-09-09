//
//  AnalysisTool.swift — the contract every study implements.
//
//  Use case first (`category`, what the user came here with), function as
//  badges (`functions`, what composes). `requirements` is why a tool greys out
//  instead of lying: no box, no reference frame, no groups, no side file.
//

import Foundation

/// Inspector grouping — the problem the user arrived with.
public enum ToolCategory: String, Codable, CaseIterable {
    case surfacesDeposition, adhesionBinding, mechanicsDeformation, structureOrder, renderingExport

    public var title: String {
        switch self {
        case .surfacesDeposition: return "Surfaces & deposition"
        case .adhesionBinding: return "Adhesion & binding"
        case .mechanicsDeformation: return "Mechanics & deformation"
        case .structureOrder: return "Structure & order"
        case .renderingExport: return "Rendering & export"
        }
    }
}

/// What a tool produces — badges, and what composes with what.
public enum ToolFunction: String, Codable, CaseIterable {
    case perAtomField, profile, scalar, timeSeries
}

/// What a tool needs from the data before it can run at all.
public enum ToolRequirement: String, Codable, CaseIterable {
    case box, referenceFrame, groups, sideFile
}

/// Everything a tool needs besides the frame itself.
public final class AnalysisContext {
    /// Undeformed / t=0 frame for tools that measure change (strain, MSD).
    public let referenceFrame: Frame?
    public let referenceFrameIndex: Int?
    public let frameIndex: Int
    /// Polled by long loops; a cancelled tool must return promptly.
    public let isCancelled: () -> Bool
    /// 1 = every atom; n > 1 = strided preview (label the result).
    public let stride: Int
    /// The trajectory file, when known: tools with `.sideFile` (pull-off
    /// energetics) look for their companions (force_curve.csv, config.json,
    /// outcomes.json) next to it. nil for in-memory frames.
    public let sourceURL: URL?
    /// The whole trajectory, for trajectory-level quantities (RMSF, H-bond
    /// lifetimes, clustering, PCA). Frames share storage with the caller (COW),
    /// so this costs nothing to pass. nil when only one frame exists.
    public let trajectory: Trajectory?
    /// Changes whenever `trajectory` changes (file load, live follow); tools
    /// that cache trajectory-level results key on it. 0 = unknown/ephemeral.
    public let trajectoryGeneration: Int

    private let neighborCache: NeighborCache

    public init(frameIndex: Int = 0,
                referenceFrame: Frame? = nil,
                referenceFrameIndex: Int? = nil,
                isCancelled: @escaping () -> Bool = { false },
                stride: Int = 1,
                neighborCache: NeighborCache = NeighborCache(),
                sourceURL: URL? = nil,
                trajectory: Trajectory? = nil,
                trajectoryGeneration: Int = 0) {
        self.frameIndex = frameIndex
        self.referenceFrame = referenceFrame
        self.referenceFrameIndex = referenceFrameIndex
        self.isCancelled = isCancelled
        self.stride = max(1, stride)
        self.neighborCache = neighborCache
        self.sourceURL = sourceURL
        self.trajectory = trajectory
        self.trajectoryGeneration = trajectoryGeneration
    }

    /// Shared neighbour list for this frame/cutoff — several tools in one
    /// inspector pass would otherwise each rebuild the same grid.
    public func neighborList(for frame: Frame, cutoff: Double) -> NeighborList {
        neighborCache.list(frameIndex: frameIndex, cutoff: cutoff, isCancelled: isCancelled) {
            NeighborList(frame: frame, cutoff: cutoff, isCancelled: self.isCancelled)
        }
    }
}

/// Tiny keyed cache of neighbour lists, shared across tools and contexts.
/// Deliberately small: neighbour lists are big and cheap to rebuild.
public final class NeighborCache {
    private struct Key: Hashable { let frameIndex: Int; let cutoffBits: UInt64 }
    private let lock = NSLock()
    private var entries: [(key: Key, list: NeighborList)] = []
    private let capacity: Int

    public init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    func list(frameIndex: Int, cutoff: Double, isCancelled: () -> Bool,
              build: () -> NeighborList) -> NeighborList {
        let key = Key(frameIndex: frameIndex, cutoffBits: cutoff.bitPattern)
        lock.lock()
        if let hit = entries.first(where: { $0.key == key })?.list { lock.unlock(); return hit }
        lock.unlock()

        let built = build()                       // built outside the lock: it is the slow part
        guard !built.wasCancelled else { return built }   // never cache a partial build
        lock.lock()
        entries.append((key, built))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        return built
    }

    public func removeAll() { lock.lock(); entries.removeAll(); lock.unlock() }
}

public enum AnalysisError: Error, LocalizedError, Equatable {
    case missingRequirement(ToolRequirement)
    case notApplicable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingRequirement(let r): return "This tool needs \(r.rawValue) and the data has none."
        case .notApplicable(let why): return why
        case .cancelled: return "Analysis cancelled."
        }
    }
}

/// One study. Static because a tool is a method, not an object: the registry
/// holds types, the parameters travel with the call.
public protocol AnalysisTool {
    associatedtype Parameters: Codable & Equatable

    static var id: String { get }
    static var title: String { get }
    static var category: ToolCategory { get }
    static var functions: Set<ToolFunction> { get }
    static var requirements: Set<ToolRequirement> { get }
    static var defaultParameters: Parameters { get }
    /// Predicted cost in microseconds — the governor defers tools that would
    /// blow the frame budget during playback. Superseded by measurement.
    static func estimatedCost(atoms: Int, params: Parameters) -> Double
    /// Can the live overlay run on a strided subset of atoms?
    static var supportsStridedPreview: Bool { get }
    static func analyze(frame: Frame, context: AnalysisContext, params: Parameters) throws -> ToolResult
}

/// UI-facing description of a registered tool (no associated types).
public struct ToolMetadata: Codable, Equatable {
    public let id: String
    public let title: String
    public let category: ToolCategory
    public let functions: [ToolFunction]
    public let requirements: [ToolRequirement]
    public let supportsStridedPreview: Bool
}

/// Type-erased tool: parameters cross this boundary as JSON, which is also how
/// they are persisted and how MCP/CLI will pass them.
public struct AnyAnalysisTool {
    public let metadata: ToolMetadata
    public let defaultParametersJSON: Data
    private let _analyze: (Frame, AnalysisContext, Data?) throws -> ToolResult
    private let _cost: (Int, Data?) -> Double

    public init<T: AnalysisTool>(_ type: T.Type) {
        metadata = ToolMetadata(id: T.id, title: T.title, category: T.category,
                                functions: T.functions.sorted { $0.rawValue < $1.rawValue },
                                requirements: T.requirements.sorted { $0.rawValue < $1.rawValue },
                                supportsStridedPreview: T.supportsStridedPreview)
        defaultParametersJSON = (try? JSONEncoder().encode(T.defaultParameters)) ?? Data()
        _analyze = { frame, context, json in
            try T.analyze(frame: frame, context: context, params: Self.decode(T.self, json))
        }
        _cost = { atoms, json in
            T.estimatedCost(atoms: atoms, params: Self.decode(T.self, json))
        }
    }

    /// Parameters as JSON; nil or malformed falls back to the tool's defaults.
    private static func decode<T: AnalysisTool>(_ type: T.Type, _ json: Data?) -> T.Parameters {
        guard let json, !json.isEmpty,
              let decoded = try? JSONDecoder().decode(T.Parameters.self, from: json) else {
            return T.defaultParameters
        }
        return decoded
    }

    public func analyze(frame: Frame, context: AnalysisContext, parametersJSON: Data? = nil) throws -> ToolResult {
        try _analyze(frame, context, parametersJSON)
    }

    public func estimatedCost(atoms: Int, parametersJSON: Data? = nil) -> Double {
        _cost(atoms, parametersJSON)
    }
}
