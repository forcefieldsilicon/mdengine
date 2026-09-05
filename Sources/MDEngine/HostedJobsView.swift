import SwiftUI
import AppKit
import LAMMPSCore

/// The app's side of the hosted GPU tier (GJOB-091): File ▸ Run Accelerated…
/// submits a deck, the Accelerated Runs window shows live thermo, and a finished
/// job's trajectory opens in the viewer by itself. All HostedClient calls are
/// synchronous, so every one of them runs on `queue`, never on main.
@MainActor
final class HostedJobsModel: ObservableObject {
    @Published var jobs: [HostedJobStatus] = []
    @Published var balance: Double?
    @Published var busy = false
    @Published var lastError: String?
    @Published var hasCredentials = HostedCredentials.load() != nil
    /// Jobs whose results were already downloaded and opened — never re-open on the next poll.
    private var opened: Set<String> = []
    private var timer: Timer?
    private let queue = DispatchQueue(label: "mdengine.hosted", qos: .userInitiated)
    /// Set by the app: how to show a fetched trajectory.
    var openTrajectory: ((URL) -> Void)?

    // MARK: polling

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        hasCredentials = HostedCredentials.load() != nil
        guard hasCredentials else { return }
        queue.async { [weak self] in
            do {
                let client = try HostedClient.fromSavedCredentials()
                let list = try client.list()
                let me = try? client.me()
                Task { @MainActor in
                    guard let self else { return }
                    self.jobs = list
                    if let me { self.balance = me.balance_usd }
                    self.lastError = nil
                    self.autoFetchFinished(list, client)
                }
            } catch {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
    }

    /// A job that just reached `done` gets its results pulled and its trajectory shown, once.
    private func autoFetchFinished(_ list: [HostedJobStatus], _ client: HostedClient) {
        for j in list where j.state == "done" && !opened.contains(j.id) {
            // Only jobs this Mac submitted (they have local bookkeeping) — not every job on the key.
            guard HostedClient.cloudMeta(j.id) != nil else { continue }
            opened.insert(j.id)
            let alreadyFetched = FileManager.default.fileExists(
                atPath: HostedClient.jobsRoot.appendingPathComponent(j.id).appendingPathComponent("results").path)
            if alreadyFetched { continue }
            fetch(j.id, client: client)
        }
    }

    // MARK: actions

    func submitPanel() {
        let panel = NSOpenPanel()
        panel.message = "Choose the LAMMPS input to run on a hosted GPU. Its whole directory is uploaded (minus trajectories/checkpoints/logs), so the deck must be self-contained."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        submit(input: url)
    }

    func submit(input: URL, gpu: String = "any", wallHours: Double = 4) {
        busy = true
        queue.async { [weak self] in
            do {
                let client = try HostedClient.fromSavedCredentials()
                let spec = HostedJobSpec(input: input.lastPathComponent,
                                         label: input.deletingPathExtension().lastPathComponent,
                                         gpu: gpu, wallLimitS: Int(wallHours * 3600))
                let id = try client.submit(input: input.path, spec: spec)
                Task { @MainActor in
                    self?.busy = false
                    self?.lastError = nil
                    self?.refresh()
                    _ = id
                }
            } catch {
                Task { @MainActor in
                    self?.busy = false
                    self?.lastError = error.localizedDescription
                    Self.alert("Could not submit \(input.lastPathComponent)", info: error.localizedDescription)
                }
            }
        }
    }

    func fetch(_ id: String, client: HostedClient? = nil) {
        queue.async { [weak self] in
            do {
                let c = try client ?? HostedClient.fromSavedCredentials()
                let dir = try c.fetch(id)
                let traj = HostedClient.primaryTrajectory(in: dir)
                Task { @MainActor in
                    self?.lastError = nil
                    if let traj { self?.openTrajectory?(traj) }
                    else { NSWorkspace.shared.open(dir) }   // no trajectory in the deck's output: show the folder
                }
            } catch {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
    }

    func cancel(_ id: String) {
        queue.async { [weak self] in
            do { _ = try HostedClient.fromSavedCredentials().cancel(id) }
            catch { Task { @MainActor in self?.lastError = error.localizedDescription } }
            Task { @MainActor in self?.refresh() }
        }
    }

    func revealResults(_ id: String) {
        let dir = HostedClient.jobsRoot.appendingPathComponent(id).appendingPathComponent("results")
        if FileManager.default.fileExists(atPath: dir.path) { NSWorkspace.shared.open(dir) }
        else { fetch(id) }
    }

    static func alert(_ message: String, info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }
}

/// Window ▸ Accelerated Runs: one row per hosted job, live thermo for the selected one.
struct HostedJobsView: View {
    @ObservedObject var model: HostedJobsModel
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasCredentials {
                ContentUnavailableView {
                    Label("No API key", systemImage: "key")
                } description: {
                    Text("Accelerated runs use prepaid GPU credits. Add your key in Settings ▸ Accelerated, or get one with a credit pack.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                    Link("Get credits", destination: HostedLinks.credits)
                }
            } else {
                HSplitView {
                    List(model.jobs, id: \.id, selection: $selected) { j in
                        HStack {
                            Circle().fill(color(j.state)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(j.id).font(.system(.body, design: .monospaced))
                                Text(line(j)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contextMenu {
                            if j.isTerminal { Button("Open results") { model.revealResults(j.id) } }
                            else { Button("Cancel job") { model.cancel(j.id) } }
                        }
                        .tag(j.id)
                    }
                    .frame(minWidth: 320)
                    detail
                        .frame(minWidth: 380)
                }
            }
            Divider()
            HStack {
                Button { model.submitPanel() } label: { Label("Run Accelerated…", systemImage: "bolt.fill") }
                    .disabled(!model.hasCredentials || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                if let e = model.lastError {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(1).help(e)
                }
                if let b = model.balance {
                    Text(String(format: "Balance $%.2f", b)).font(.callout).monospacedDigit()
                }
                Link("Buy credits", destination: HostedLinks.credits).font(.callout)
            }
            .padding(10)
        }
        .frame(minWidth: 720, minHeight: 360)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    @ViewBuilder private var detail: some View {
        if let id = selected, let j = model.jobs.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(j.summary).font(.headline).textSelection(.enabled)
                ScrollView {
                    Text((j.thermo_tail ?? []).isEmpty ? "(no thermo yet)" : (j.thermo_tail ?? []).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if j.isTerminal {
                        Button("Open results") { model.revealResults(j.id) }
                    } else {
                        Button("Cancel") { model.cancel(j.id) }
                    }
                    Spacer()
                }
            }
            .padding(12)
        } else {
            ContentUnavailableView("Select a job", systemImage: "list.bullet",
                                   description: Text("Live thermo output shows here. Finished runs open in the viewer automatically."))
        }
    }

    private func line(_ j: HostedJobStatus) -> String {
        var parts: [String] = [j.state]
        if let g = j.gpu, !["created", "uploaded"].contains(j.state) { parts.append(g) }
        if let c = j.cost_usd, c > 0 { parts.append(String(format: "$%.3f", c)) }
        if let created = j.created { parts.append(created) }
        return parts.joined(separator: " · ")
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "done": return .green
        case "failed": return .red
        case "cancelled": return .gray
        case "running", "uploading": return .blue
        default: return .orange
        }
    }
}

enum HostedLinks {
    /// Credit packs (Stripe Payment Links live behind this page — GJOB-096).
    static let credits = URL(string: "https://forcefieldsilicon.com/mdengine#credits")!
}

/// Settings ▸ Accelerated: API key + endpoint, verified against the endpoint before saving.
struct HostedSettingsView: View {
    @State private var apiKey = HostedCredentials.load()?.apiKey ?? ""
    @State private var endpoint = HostedCredentials.load()?.endpoint ?? ""
    @State private var advanced = false
    @State private var status: String = ""
    @State private var checking = false

    var body: some View {
        Form {
            SecureField("API key", text: $apiKey, prompt: Text("mde_…"))
                .textFieldStyle(.roundedBorder)
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                TextField("Endpoint", text: $endpoint, prompt: Text(HostedCredentials.productionEndpoint))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Button(checking ? "Checking…" : "Verify & Save") { verifyAndSave() }
                    .disabled(checking || !apiKey.hasPrefix("mde_"))
                Button("Remove key") {
                    HostedCredentials.clear(); apiKey = ""; status = "key removed"
                }
                .disabled(HostedCredentials.load() == nil)
                Spacer()
                Link("Get credits", destination: HostedLinks.credits)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(status.hasPrefix("✓") ? Color.secondary : Color.red)
            }
            Text("The key is stored in ~/.mdengine/credentials (readable only by you) and shared with the mdengine CLI and MCP server.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }

    private func verifyAndSave() {
        checking = true
        let creds = HostedCredentials(apiKey: apiKey.trimmingCharacters(in: .whitespaces),
                                      endpoint: endpoint.isEmpty ? nil : endpoint)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            do {
                let me = try HostedClient(credentials: creds).me()
                try creds.save()
                result = String(format: "✓ key saved — balance $%.2f", me.balance_usd)
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async { status = result; checking = false }
        }
    }
}
