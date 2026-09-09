//
//  ToolRegistry.swift — the catalogue of built-in tools.
//
//  Holds the metadata the inspector's "+ Add tool" picker lists, the enabled
//  set and per-tool parameters (persisted through an injectable store so the
//  core stays testable without UserDefaults), and the measured cost the
//  governor uses to defer expensive tools during playback.
//

import Foundation

/// Persistence seam: the app injects a UserDefaults-backed store, tests get the
/// in-memory default.
public protocol ToolKeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class InMemoryToolStore: ToolKeyValueStore {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return storage[key]
    }
    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
}

public final class ToolRegistry {
    /// Built-ins, registered once. The app uses this; tests build their own.
    public static let shared: ToolRegistry = {
        let r = ToolRegistry()
        r.registerBuiltIns()
        return r
    }()

    private let lock = NSLock()
    private var tools: [String: AnyAnalysisTool] = [:]
    private var order: [String] = []
    /// Last 8 measured µs/atom per tool; the median resists one cold-cache outlier.
    private var measurements: [String: [Double]] = [:]
    private let store: ToolKeyValueStore

    public init(store: ToolKeyValueStore = InMemoryToolStore()) { self.store = store }

    public func registerBuiltIns() {
        register(ZProfileTool.self)
        register(ColumnFieldTool.self)
        register(CrystallinityTool.self)
        register(PTMTool.self)
        register(ConformationTool.self)
        register(RDFTool.self)
        register(DiffusionTool.self)
        register(ThermoTool.self)
        register(AdhesionTool.self)
        register(PullOffEnergeticsTool.self)
        register(FEPResultsTool.self)
        register(KineticsTool.self)
        register(DeformationTool.self)
    }

    public func register<T: AnalysisTool>(_ type: T.Type) {
        lock.lock(); defer { lock.unlock() }
        if tools[T.id] == nil { order.append(T.id) }
        tools[T.id] = AnyAnalysisTool(type)
    }

    public func tool(_ id: String) -> AnyAnalysisTool? {
        lock.lock(); defer { lock.unlock() }; return tools[id]
    }

    /// Picker listing: grouped by category, alphabetical inside a category.
    public var metadata: [ToolMetadata] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { tools[$0]?.metadata }
            .sorted { a, b in
                a.category == b.category ? a.title < b.title
                                         : a.category.rawValue < b.category.rawValue
            }
    }

    // MARK: - Enabled set (persisted as `tools.enabled`)

    private static let enabledKey = "tools.enabled"

    public var enabled: Set<String> {
        get {
            guard let data = store.data(forKey: Self.enabledKey),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(ids)
        }
        set { store.set(try? JSONEncoder().encode(newValue.sorted()), forKey: Self.enabledKey) }
    }

    public func setEnabled(_ on: Bool, for id: String) {
        var set = enabled
        if on { set.insert(id) } else { set.remove(id) }
        enabled = set
    }

    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    // MARK: - Parameters (persisted as `tools.<id>.params`)

    /// Stored parameters JSON, or the tool's defaults when nothing is stored.
    public func parameters(for id: String) -> Data? {
        if let data = store.data(forKey: "tools.\(id).params") { return data }
        return tool(id)?.defaultParametersJSON
    }

    public func setParameters(_ json: Data?, for id: String) {
        store.set(json, forKey: "tools.\(id).params")
    }

    public func setParameters<T: AnalysisTool>(_ params: T.Parameters, for type: T.Type) {
        setParameters(try? JSONEncoder().encode(params), for: T.id)
    }

    /// Cache key component: parameters that differ must not share a result.
    public func parametersHash(for id: String) -> Int {
        (parameters(for: id) ?? Data()).hashValue
    }

    // MARK: - Cost model

    /// Record one real run. `atoms` is what the tool actually walked (a strided
    /// preview passes its subset size, so µs/atom stays comparable).
    public func recordMeasurement(toolId: String, atoms: Int, microseconds: Double) {
        guard atoms > 0, microseconds >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var samples = measurements[toolId] ?? []
        samples.append(microseconds / Double(atoms))
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
        measurements[toolId] = samples
    }

    /// Median µs/atom from the last 8 runs; nil before the tool has ever run.
    public func measuredMicrosecondsPerAtom(toolId: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let samples = measurements[toolId], !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Expected cost in µs — measured when we have it, the tool's declaration
    /// otherwise (measurement beats a guess, always).
    public func estimatedCost(toolId: String, atoms: Int) -> Double {
        if let perAtom = measuredMicrosecondsPerAtom(toolId: toolId) {
            return perAtom * Double(atoms)
        }
        return tool(toolId)?.estimatedCost(atoms: atoms, parametersJSON: parameters(for: toolId)) ?? 0
    }
}
