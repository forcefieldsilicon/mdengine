import SwiftUI
import LAMMPSCore
import MDRender

/// The inspector's Tools area (design §1 "App"): a catalogue picker grouped by
/// use case with function badges, then one collapsible section per added tool.
/// A section computes only while enabled AND expanded (or its tool is the
/// overlay); everything else here is display of published results.
struct ToolsArea: View {
    let model: ContentViewModel
    @ObservedObject var state: InspectorState
    @State private var showingCatalogue = false

    var body: some View {
        Section {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Button {
                    showingCatalogue = true
                } label: {
                    Label("Add tool", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Add an analysis tool from the catalogue (crystallinity, adhesion, colour by column…)")
            }
            if state.addedTools.isEmpty {
                Text("No tools added. Tools compute only while their section is expanded.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showingCatalogue) {
            ToolCatalogueSheet(model: model, state: state)
        }
        ForEach(state.addedTools, id: \.self) { id in
            if let meta = model.registry.metadata.first(where: { $0.id == id }) {
                CollapsibleSection(meta.title, key: "inspExpTool.\(id)", initiallyExpanded: true) {
                    ToolSectionView(model: model, state: state, meta: meta)
                }
            }
        }
    }
}

// MARK: - Catalogue

/// One line of "when to use" per built-in; the method details live in the manual.
private let toolWhenToUse: [String: String] = [
    "z_profile": "Where did the deposited species end up: penetration, at-surface, in-flight, per depth bin.",
    "column_field": "Colour atoms by depth, charge, potential energy or any dump column; profile of it along an axis.",
    "conformation": "Is the protein holding its fold: RMSD to a reference, radius of gyration, per-atom RMSF, DSSP secondary structure, frame clustering and PCA over the trajectory.",
    "rdf": "How is the material packed: pair distribution g(r) for chosen species, first peak/minimum, per-atom coordination number.",
    "diffusion": "How mobile are the atoms: mean squared displacement vs time with periodic unwrapping, Einstein diffusion coefficient with uncertainty.",
    "thermo": "What did the run report: LAMMPS log.lammps thermo columns aligned to the frames; stress–strain and Young's modulus when stress and box columns exist.",
    "adhesion": "Is the ligand still bound: A–B contacts, hydrogen bonds, separation, per-residue contact map, rupture frame over time.",
    "deformation": "Where did the material yield: per-atom shear and volumetric strain vs a reference frame, D²min (plastic rearrangement), displacement, MSD, von Mises stress when the dump has stress columns.",
    "crystallinity": "Is my oxide amorphous, where are the grains: fcc/hcp/bcc/other per atom (adaptive CNA), crystalline fraction, q̄6 amorphicity, profile along z.",
    "ptm": "Grains and orientation: template matching robust to thermal noise, per-atom lattice orientation (IPF colour), grain boundaries by disorientation, grain count.",
    "kinetics_tramd": "How long does it stay bound: τRAMD residence time with bootstrap CI from tramd_times.csv, survival curve over replicas; k_off rank order, not absolute.",
    "fep_results": "Which compound to make next: ranked ΔΔG ± uncertainty from an OpenFE relative binding free energy run (results.json), overlap and convergence flags, cycle closure.",
    "pulloff_energetics": "What did the pull cost: F(t) from force_curve.csv, rupture force, work of separation, Bell–Evans across velocities and Jarzynski only when the seeds justify it.",
]

private struct ToolCatalogueSheet: View {
    let model: ContentViewModel
    @ObservedObject var state: InspectorState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a tool").font(.title3.bold())
            Text("Grouped by the question you arrived with. Badges say what a tool produces; a per-atom field can colour the view and feed the Z-profile.")
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ToolCategory.allCases, id: \.self) { category in
                        let tools = model.registry.metadata.filter { $0.category == category }
                        if !tools.isEmpty {
                            Text(category.title).font(.headline).padding(.top, 6)
                            ForEach(tools, id: \.id) { meta in
                                catalogueRow(meta)
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 520, height: 440)
    }

    private func catalogueRow(_ meta: ToolMetadata) -> some View {
        let added = state.addedTools.contains(meta.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(meta.title).bold()
                    FunctionBadges(functions: meta.functions)
                }
                Text(toolWhenToUse[meta.id] ?? "").font(.caption).foregroundColor(.secondary)
                if !meta.requirements.isEmpty {
                    Text("Needs: " + meta.requirements.map(\.rawValue).joined(separator: ", "))
                        .font(.caption2).foregroundColor(.orange)
                }
            }
            Spacer()
            Button(added ? "Added" : "Add") { model.addTool(meta.id) }
                .disabled(added)
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct FunctionBadges: View {
    let functions: [ToolFunction]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(functions, id: \.self) { f in
                Text(label(f))
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .help(help(f))
            }
        }
    }
    private func label(_ f: ToolFunction) -> String {
        switch f {
        case .perAtomField: return "field"
        case .profile: return "profile"
        case .scalar: return "scalar"
        case .timeSeries: return "series"
        }
    }
    private func help(_ f: ToolFunction) -> String {
        switch f {
        case .perAtomField: return "Publishes a value per atom — can colour the view and feed the Z-profile"
        case .profile: return "Bins a quantity along an axis"
        case .scalar: return "One number per frame"
        case .timeSeries: return "The scalar can be charted over all frames"
        }
    }
}

// MARK: - One tool's section

struct ToolSectionView: View {
    let model: ContentViewModel
    @ObservedObject var state: InspectorState
    let meta: ToolMetadata

    private var panel: InspectorState.ToolPanel { state.tools[meta.id] ?? .init() }
    private var enabled: Bool { model.registry.isEnabled(meta.id) }

    var body: some View {
        // `toolSettingsGeneration` is read so the section re-renders when the
        // (non-observable) registry store changes enabled/params.
        let _ = state.toolSettingsGeneration
        HStack {
            Toggle("Enabled", isOn: Binding(get: { enabled }, set: { model.setToolEnabled(meta.id, $0) }))
                .toggleStyle(.checkbox)
                .help("Off = loaded but idle: no compute, no overlay")
            FunctionBadges(functions: meta.functions)
            Spacer()
            if panel.computing && !state.isPlaying { ProgressView().controlSize(.mini) }
            if state.isPlaying && enabled {
                Text("paused during playback").font(.caption2).foregroundColor(.orange)
                    .help("Sections freeze while playing (an inspector refresh costs a full re-layout); the overlay keeps following the frame. Refreshes when playback stops.")
            }
        }
        if meta.requirements.contains(.referenceFrame) {
            LabeledContent("Reference frame") {
                HStack(spacing: 6) {
                    TextField("", value: Binding(get: { state.referenceFrame },
                                                 set: { model.setReferenceFrame($0) }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.trailing)
                    Button("Use current") { model.setReferenceFrame(model.frameIndex) }
                        .controlSize(.small)
                        .help("Strain, displacement and D²min are measured against this frame (default: frame 0)")
                }
            }
        }
        ToolParametersEditor(model: model, state: state, meta: meta)
        if let error = panel.error {
            Text(error).font(.caption).foregroundColor(.orange)
        }
        if let result = panel.result {
            ForEach(result.summary.indices, id: \.self) { i in
                let row = result.summary[i]
                LabeledContent(row.label) {
                    Text(row.unit.map { "\(row.value) \($0)" } ?? row.value).monospacedDigit()
                }
            }
            if let profile = result.profile { ProfileChart(profile: profile) }
            ForEach(result.notes, id: \.self) { Text($0).font(.caption2).foregroundColor(.secondary) }
            if meta.functions.contains(.perAtomField) {
                Toggle("Overlay on view", isOn: Binding(
                    get: { state.overlayTool == meta.id },
                    set: { model.setOverlayTool($0 ? meta.id : nil) }))
                    .toggleStyle(.checkbox)
                    .disabled(!enabled || result.field == nil)
                    .help("Colour atoms by this tool's field; the legend appears bottom-right and bakes into snapshots and video")
            }
        } else if enabled && !panel.computing && panel.error == nil {
            Text("Expand to compute…").font(.caption).foregroundColor(.secondary)
        }
        if meta.functions.contains(.timeSeries) {
            seriesBlock
        }
        HStack {
            Button("Export CSV…") { model.exportToolCSV(meta.id) }
                .disabled(panel.result == nil)
            Button("Export Excel…") { model.exportToolXLSX(meta.id) }
                .disabled(panel.result == nil)
                .help("Workbook: Summary, Profile, Series and (≤ 100 k atoms) the per-atom Field as sheets")
            if meta.functions.contains(.perAtomField) {
                Button("Snapshot PNG…") { model.snapshotTool(meta.id) }
                    .disabled(panel.result?.field == nil)
                    .help("Current view coloured by this field, legend baked in (same size as Video export)")
            }
            Spacer()
            Button(role: .destructive) { model.removeTool(meta.id) } label: { Text("Remove") }
                .controlSize(.small)
        }
        if panel.lastMs > 0 {
            Text(String(format: "last compute %.1f ms", panel.lastMs))
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var seriesBlock: some View {
        if let progress = panel.seriesProgress {
            HStack {
                ProgressView(value: progress)
                Button("Cancel") { model.cancelTimeSeries(meta.id) }.controlSize(.small)
            }
        } else {
            HStack {
                Button(panel.series.isEmpty ? "Chart over all frames…"
                       : (panel.seriesFromTool ? "Recompute chart per frame…" : "Recompute chart…")) {
                    model.runTimeSeries(meta.id)
                }
                .disabled(!enabled || state.frameCount < 2)
                .help("Runs the tool on every frame (explicit, cancellable). Click a point to jump to that frame.")
                Spacer()
            }
        }
        if !panel.series.isEmpty {
            SeriesChart(series: panel.series, cursor: state.chartFrame,
                        label: panel.result?.seriesLabel ?? panel.result?.summary.first?.label ?? meta.title) { frame in
                model.stopPlayback()
                model.frameIndex = frame
            }
        }
    }
}

// MARK: - Parameters

/// Enumerated string parameters get a Picker instead of a free text field.
/// Generic keys apply to every tool; per-tool keys are listed by tool id.
private let genericChoices: [String: [String]] = [
    "profileAxis": ["x", "y", "z"],
    "colormap": FieldColors.colormapNames,
]
private let toolChoices: [String: [String: [String]]] = [
    "crystallinity": ["method": ["acna", "q6"]],
    "deformation": ["quantity": ["shear", "volumetric", "d2min", "displacement", "rearranged", "vonmises_stress"]],
    "ptm": ["quantity": ["structure", "orientation", "rmsd", "gb", "shear"]],
    "fep_results": ["sortBy": ["rank", "ddG", "error"]],
    "conformation": ["selection": ["ca", "backbone", "heavy", "all"], "quantity": ["rmsf", "dssp", "displacement"]],
    "adhesion": ["quantity": ["contacts", "interactions"]],
    "thermo": ["alignBy": ["step", "index"]],
]

/// Generic editor over the tool's JSON parameters (Bool / number / string
/// top-level keys), with a purpose-built row set for "Colour by column".
struct ToolParametersEditor: View {
    let model: ContentViewModel
    @ObservedObject var state: InspectorState
    let meta: ToolMetadata

    private var params: [String: Any] {
        guard let data = model.registry.parameters(for: meta.id),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func set(_ key: String, _ value: Any?) {
        var p = params
        if let value { p[key] = value } else { p.removeValue(forKey: key) }
        model.setToolParameters(meta.id, json: try? JSONSerialization.data(withJSONObject: p))
    }

    var body: some View {
        let _ = state.toolSettingsGeneration
        let p = params
        if meta.id == AdhesionTool.id {
            GroupSelectorEditor(title: "Group A (receptor)", selector: p["groupA"] as? [String: Any],
                                labels: state.availableLabels) { set("groupA", $0) }
            GroupSelectorEditor(title: "Group B (ligand)", selector: p["groupB"] as? [String: Any],
                                labels: state.availableLabels) { set("groupB", $0) }
            numberRow("Contact cutoff (Å)", key: "contactCutoff", p)
            numberRow("H-bond distance (Å)", key: "hbondDistance", p)
            numberRow("H-bond angle (°)", key: "hbondAngle", p)
            Toggle("Per-residue contact map", isOn: Binding(get: { p["perResidue"] as? Bool ?? true },
                                                          set: { set("perResidue", $0) }))
                .toggleStyle(.checkbox)
        } else if meta.id == PullOffEnergeticsTool.id {
            SideFileRow(title: "Force curve CSV", path: p["csvPath"] as? String,
                        placeholder: "auto: force_curve.csv next to the trajectory",
                        chooseDirectories: false) { set("csvPath", $0) }
            RunDirsEditor(dirs: p["runDirs"] as? [String] ?? []) { set("runDirs", $0) }
            Picker("Frame alignment", selection: Binding(get: { p["frameAlignment"] as? String ?? "row" },
                                                          set: { set("frameAlignment", $0) })) {
                Text("row i ↔ frame i").tag("row")
                Text("by time_ps").tag("time")
            }
            LabeledContent("Seed") {
                TextField("auto", text: Binding(get: { (p["seed"] as? NSNumber).map { "\($0)" } ?? "" },
                                                set: { set("seed", Int($0)) }))
                    .textFieldStyle(.roundedBorder).frame(width: 110)
            }
            numberRow("Temperature (K)", key: "temperature_K", p)
        } else if meta.id == ColumnFieldTool.id {
            Picker("Column", selection: Binding(get: { p["column"] as? String ?? "z" }, set: { set("column", $0) })) {
                ForEach(state.availableColumns, id: \.self) { Text($0) }
            }
            Picker("Colormap", selection: Binding(get: { p["colormap"] as? String ?? "viridis" }, set: { set("colormap", $0) })) {
                ForEach(FieldColors.colormapNames, id: \.self) { Text($0) }
            }
            Picker("Profile along", selection: Binding(get: { p["profileAxis"] as? String ?? "z" }, set: { set("profileAxis", $0) })) {
                ForEach(["x", "y", "z"], id: \.self) { Text($0) }
            }
            numberRow("Bins", key: "bins", p)
        } else {
            ForEach(p.keys.sorted(), id: \.self) { key in
                genericRow(key, p[key])
            }
        }
    }

    @ViewBuilder private func genericRow(_ key: String, _ value: Any?) -> some View {
        if let b = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            Toggle(key, isOn: Binding(get: { b }, set: { set(key, $0) })).toggleStyle(.checkbox)
        } else if value is NSNumber {
            numberRow(key, key: key, [key: value as Any])
        } else if let s = value as? String {
            if let options = toolChoices[meta.id]?[key] ?? genericChoices[key] {
                Picker(key, selection: Binding(get: { s }, set: { set(key, $0) })) {
                    ForEach(options, id: \.self) { Text($0) }
                }
            } else {
                LabeledContent(key) {
                    TextField("", text: Binding(get: { s }, set: { set(key, $0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                }
            }
        } else if value == nil || value is NSNull {
            LabeledContent(key) { Text("auto").foregroundColor(.secondary) }
        } else {
            LabeledContent(key) {
                Text((try? String(data: JSONSerialization.data(withJSONObject: value!), encoding: .utf8)) ?? "…")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }

    private func numberRow(_ title: String, key: String, _ p: [String: Any]) -> some View {
        let current = (p[key] as? NSNumber)?.doubleValue ?? 0
        return LabeledContent(title) {
            TextField("", value: Binding(get: { current }, set: { new in
                // Keep integers integral so Codable Int parameters still decode.
                if current.rounded() == current, new.rounded() == new { set(key, Int(new)) } else { set(key, new) }
            }), format: .number)
            .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Charts

/// Bars of a binned profile: the Z-profile histogram generalized to any tool.
struct ProfileChart: View {
    let profile: Profile

    var body: some View {
        let vals = profile.values
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let span = max(1e-9, hi - lo)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(vals.indices, id: \.self) { i in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(height: max(2, 36 * CGFloat((vals[i] - lo) / span)))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 38, alignment: .bottom)
            .help("\(profile.valueLabel) per \(profile.axisLabel) bin (\(vals.count) bins); export CSV for the numbers")
            HStack {
                Text(String(format: "%.3g", profile.edges.first ?? 0)).font(.system(size: 8)).monospacedDigit()
                Spacer()
                Text(profile.axisLabel).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.3g", profile.edges.last ?? 0)).font(.system(size: 8)).monospacedDigit()
            }
            Text("\(profile.valueLabel): \(String(format: "%.3g", lo)) … \(String(format: "%.3g", hi))")
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

/// Scalar over frames; click = jump to that frame. Drawn with Canvas so a
/// 1000-frame series is one draw call, not 1000 views.
struct SeriesChart: View {
    let series: [Int: Double]
    let cursor: Int
    let label: String
    let onSelect: (Int) -> Void

    var body: some View {
        let keys = series.keys.sorted()
        let vals = keys.map { series[$0]! }
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let span = max(1e-12, hi - lo)
        let maxKey = max(1, keys.last ?? 1)
        VStack(alignment: .leading, spacing: 2) {
            Canvas { ctx, size in
                var path = Path()
                for (n, k) in keys.enumerated() {
                    let x = size.width * CGFloat(k) / CGFloat(maxKey)
                    let y = size.height - size.height * CGFloat((vals[n] - lo) / span)
                    n == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
                ctx.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
                let cx = size.width * CGFloat(cursor) / CGFloat(maxKey)
                var marker = Path()
                marker.move(to: CGPoint(x: cx, y: 0)); marker.addLine(to: CGPoint(x: cx, y: size.height))
                ctx.stroke(marker, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(height: 56)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { location in
                            let frame = Int((location.x / geo.size.width * CGFloat(maxKey)).rounded())
                            onSelect(max(0, min(maxKey, frame)))
                        }
                }
            )
            HStack {
                Text(String(format: "%.4g", lo)).font(.system(size: 8)).monospacedDigit()
                Spacer()
                Text("\(label) vs frame · \(keys.count) pts").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.4g", hi)).font(.system(size: 8)).monospacedDigit()
            }
        }
    }
}

// MARK: - Legend on the view

/// Bottom-right legend for the overlay tool's field; same model the exporter
/// bakes into PNG/MP4 (FieldColors.Legend).
struct OverlayLegendView: View {
    @ObservedObject var state: InspectorState

    var body: some View {
        if let id = state.overlayTool, let field = state.tools[id]?.result?.field {
            legend(FieldColors.legend(for: field))
                .padding(8)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder private func legend(_ l: FieldColors.Legend) -> some View {
        switch l {
        case .swatches(let title, let entries):
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.bold())
                ForEach(entries.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: Double(entries[i].color.x), green: Double(entries[i].color.y),
                                        blue: Double(entries[i].color.z)))
                            .frame(width: 12, height: 12)
                        Text(entries[i].label).font(.caption)
                    }
                }
            }
        case .colorBar(let title, let lo, let hi, let name):
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.bold())
                HStack(spacing: 6) {
                    LinearGradient(gradient: Gradient(colors: (0...16).map { i in
                        let c = FieldColors.sample(name, at: Float(i) / 16)
                        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                    }), startPoint: .bottom, endPoint: .top)
                        .frame(width: 12, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    VStack {
                        Text(String(format: "%.3g", hi)).font(.caption2).monospacedDigit()
                        Spacer()
                        Text(String(format: "%.3g", lo)).font(.caption2).monospacedDigit()
                    }
                    .frame(height: 90)
                }
            }
        }
    }
}

// MARK: - Adhesion group selector

/// Edits one `GroupSelector` as the JSON the core decodes:
/// `{"kind":"label","name":"chain","values":[…]}`, `{"kind":"elements","elements":[…]}`,
/// `{"kind":"slab","axis":"z","min":…,"max":…}`, `{"kind":"all"}`, or nil (auto).
/// Label kinds are offered only for labels the loaded file actually carries.
struct GroupSelectorEditor: View {
    let title: String
    let selector: [String: Any]?
    let labels: [String: [String]]
    let onChange: ([String: Any]?) -> Void

    private var kind: String {
        guard let s = selector, let k = s["kind"] as? String else { return "auto" }
        if k == "label", let name = s["name"] as? String { return "label:" + name }
        return k
    }
    private var kindOptions: [(tag: String, label: String)] {
        var out: [(String, String)] = [("auto", "Auto (two most populous)"), ("all", "All atoms"),
                                       ("elements", "Elements"), ("slab", "Spatial slab")]
        for name in labels.keys.sorted() where name != "element" {
            out.append(("label:" + name, "Label: \(name)"))
        }
        return out
    }
    private var chosenValues: [String] {
        (selector?["values"] as? [String]) ?? (selector?["elements"] as? [String]) ?? []
    }
    private var candidateValues: [String] {
        if kind == "elements" { return labels["element"] ?? [] }
        if kind.hasPrefix("label:") { return labels[String(kind.dropFirst(6))] ?? [] }
        return []
    }

    private func setKind(_ k: String) {
        switch k {
        case "auto": onChange(nil)
        case "all": onChange(["kind": "all"])
        case "elements": onChange(["kind": "elements", "elements": []])
        case "slab": onChange(["kind": "slab", "axis": "z", "min": 0, "max": 10])
        default: onChange(["kind": "label", "name": String(k.dropFirst(6)), "values": []])
        }
    }
    private func toggleValue(_ v: String) {
        var s = selector ?? [:]
        var vals = chosenValues
        if let i = vals.firstIndex(of: v) { vals.remove(at: i) } else { vals.append(v) }
        if kind == "elements" { s["elements"] = vals } else { s["values"] = vals }
        onChange(s)
    }

    var body: some View {
        Picker(title, selection: Binding(get: { kind }, set: setKind)) {
            ForEach(kindOptions, id: \.tag) { Text($0.label).tag($0.tag) }
        }
        if !candidateValues.isEmpty {
            LabeledContent("Members") {
                Menu(chosenValues.isEmpty ? "choose…" : chosenValues.joined(separator: ", ")) {
                    ForEach(candidateValues.prefix(200), id: \.self) { v in
                        Button {
                            toggleValue(v)
                        } label: {
                            Label(v, systemImage: chosenValues.contains(v) ? "checkmark" : "")
                        }
                    }
                    if candidateValues.count > 200 { Text("… \(candidateValues.count - 200) more (edit JSON)") }
                }
                .menuStyle(.borderlessButton).frame(maxWidth: 170)
            }
        }
        if kind == "slab" {
            let s = selector ?? [:]
            Picker("Axis", selection: Binding(get: { s["axis"] as? String ?? "z" },
                                              set: { var t = s; t["axis"] = $0; onChange(t) })) {
                ForEach(["x", "y", "z"], id: \.self) { Text($0) }
            }
            HStack {
                LabeledContent("Min (Å)") {
                    TextField("", value: Binding(get: { (s["min"] as? NSNumber)?.doubleValue ?? 0 },
                                                 set: { var t = s; t["min"] = $0; onChange(t) }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                }
                LabeledContent("Max (Å)") {
                    TextField("", value: Binding(get: { (s["max"] as? NSNumber)?.doubleValue ?? 10 },
                                                 set: { var t = s; t["max"] = $0; onChange(t) }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                }
            }
        }
    }
}

// MARK: - Side-file rows (energetics)

struct SideFileRow: View {
    let title: String
    let path: String?
    let placeholder: String
    let chooseDirectories: Bool
    let onChange: (String?) -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? placeholder)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundColor(path == nil ? .secondary : .primary)
                    .frame(maxWidth: 150, alignment: .trailing)
                    .help(path ?? placeholder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = chooseDirectories
                    panel.canChooseFiles = !chooseDirectories
                    if !chooseDirectories { panel.allowedContentTypes = [.commaSeparatedText] }
                    if panel.runModal() == .OK, let url = panel.url { onChange(url.path) }
                }.controlSize(.small)
                if path != nil { Button("Auto") { onChange(nil) }.controlSize(.small) }
            }
        }
    }
}

/// Run directories pooled for Bell–Evans (≥ 3 velocities) and Jarzynski (≥ 10 seeds).
struct RunDirsEditor: View {
    let dirs: [String]
    let onChange: ([String]) -> Void

    var body: some View {
        LabeledContent("Pooled run dirs") {
            HStack(spacing: 4) {
                Text(dirs.isEmpty ? "none (single run)" : "\(dirs.count)")
                    .font(.caption).foregroundColor(dirs.isEmpty ? .secondary : .primary)
                Button("Add…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.message = "Run directories with config.json + force_curve.csv"
                    if panel.runModal() == .OK { onChange(Array(Set(dirs + panel.urls.map(\.path))).sorted()) }
                }.controlSize(.small)
                if !dirs.isEmpty { Button("Clear") { onChange([]) }.controlSize(.small) }
            }
        }
        ForEach(dirs, id: \.self) { d in
            HStack {
                Text((d as NSString).abbreviatingWithTildeInPath).font(.caption2).lineLimit(1)
                    .truncationMode(.middle).foregroundColor(.secondary)
                Spacer()
                Button { onChange(dirs.filter { $0 != d }) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).controlSize(.mini)
            }
        }
    }
}
