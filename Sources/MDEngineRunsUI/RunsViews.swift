import SwiftUI
import LAMMPSCore

/// The tracker's screens (GJOB-121 key entry + balance, GJOB-122 list/detail/cancel/results).
///
/// The view layer holds no arithmetic and no date maths — `JobList` in RunsModel.swift does that, where the
/// tests can reach it. These files build for iOS AND macOS so `swift build` covers them before any Xcode
/// project exists; iOS-only affordances (the share sheet) are fenced.

@MainActor
public final class RunsViewModel: ObservableObject {
    @Published public private(set) var apiKey: String?
    @Published public private(set) var account: HostedAccount?
    @Published public private(set) var jobs: [HostedJobStatus] = []
    @Published public private(set) var isLoading = false
    @Published public var error: String?
    /// Set when a results tarball has been downloaded and is ready to hand to the share sheet.
    @Published public var shareURL: URL?

    let store: CredentialStore
    let endpoint: String?
    /// True when the Keychain was unavailable and the key is in a file instead. Surfaced, never hidden.
    public let storeIsDowngraded: Bool

    public init(store: CredentialStore, endpoint: String? = nil, storeIsDowngraded: Bool = false) {
        self.store = store
        self.endpoint = endpoint
        self.storeIsDowngraded = storeIsDowngraded
        self.apiKey = store.load()
    }

    func makeClient(_ key: String) throws -> HostedClient {
        try HostedClient(credentials: HostedCredentials(apiKey: key, endpoint: endpoint))
    }
    var client: HostedClient? {
        guard let apiKey else { return nil }
        return try? makeClient(apiKey)
    }

    /// Accepts a bare key, the `mdengine login …` line, or a deep-link URL, then proves it against /v1/me
    /// before storing it. Storing first would leave the app holding a key that does not work.
    public func signIn(pasted: String) async {
        guard let key = KeyEntry.extract(from: pasted) else {
            error = "That does not look like an MDEngine key. It starts with mde_ and is 36 characters."
            return
        }
        await verifyAndStore(key)
    }

    public func handleDeepLink(_ url: URL) async {
        guard let key = KeyEntry.fromDeepLink(url) else { return }
        await verifyAndStore(key)
    }

    func verifyAndStore(_ key: String) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let probe = try makeClient(key)
            let acct = try await Task.detached { try probe.me() }.value
            try store.save(key)
            apiKey = key
            account = acct
            await refresh()
        } catch {
            self.error = (error as? HostedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func signOut() {
        store.clear(); apiKey = nil; account = nil; jobs = []; error = nil
    }

    public func refresh() async {
        guard let client else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let (acct, list) = try await Task.detached {
                (try client.me(), try client.list())
            }.value
            account = acct
            jobs = JobList.sorted(list)
        } catch {
            self.error = (error as? HostedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func cancel(_ id: String) async {
        guard let client else { return }
        do {
            _ = try await Task.detached { try client.cancel(id) }.value
            await refresh()
        } catch {
            self.error = (error as? HostedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Download the results tarball and offer it to the system — no unpacking, which is why this works on
    /// iOS at all (GJOB-122; `downloadResults` is the platform-neutral half of `fetch`).
    public func downloadResults(_ id: String) async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            shareURL = try await Task.detached { try client.downloadResults(id) }.value
        } catch {
            self.error = (error as? HostedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public var groups: [(title: String, jobs: [HostedJobStatus])] { JobList.grouped(jobs) }

    /// Refresh until nothing can change any more, then stop. Driven by a SwiftUI `.task`, so it is
    /// cancelled automatically when the view goes away — no timer to leak and none to invalidate.
    public func followLive() async {
        while !Task.isCancelled {
            guard JobList.shouldPoll(jobs) else { return }
            try? await Task.sleep(for: JobList.pollInterval)
            if Task.isCancelled { return }
            await refresh()
        }
    }
}

// MARK: - screens

public struct RunsRootView: View {
    @ObservedObject var model: RunsViewModel
    public init(model: RunsViewModel) { self.model = model }

    public var body: some View {
        Group {
            if model.apiKey == nil { KeyEntryView(model: model) } else { JobListView(model: model) }
        }
        .onOpenURL { url in Task { await model.handleDeepLink(url) } }
    }
}

public struct KeyEntryView: View {
    @ObservedObject var model: RunsViewModel
    @State private var pasted = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MDEngine Runs").font(.largeTitle.weight(.semibold))
            Text(model.storeIsDowngraded
                 ? "Paste your API key to follow your hosted GPU runs. This build cannot use the Keychain, so the key is stored in a file inside the app's sandbox."
                 : "Paste your API key to follow your hosted GPU runs. It is kept in this device's Keychain.")
                .foregroundStyle(.secondary)
            TextField("mde_…", text: $pasted, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Button {
                Task { await model.signIn(pasted: pasted) }
            } label: {
                if model.isLoading { ProgressView() } else { Text("Continue").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pasted.isEmpty || model.isLoading)
            if let e = model.error { Text(e).font(.callout).foregroundStyle(.red) }
            Spacer()
            Text("Buying credit at forcefieldsilicon.com/mdengine shows the key once; the same page can open it straight into this app.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}

public struct JobListView: View {
    @ObservedObject var model: RunsViewModel

    public var body: some View {
        NavigationStack {
            List {
                if let a = model.account {
                    Section {
                        HStack {
                            Text("Balance")
                            Spacer()
                            Text(String(format: "$%.2f", a.balance_usd)).monospacedDigit().bold()
                        }
                    } footer: {
                        Text("Credit never expires.")
                    }
                }
                ForEach(model.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.jobs, id: \.id) { job in
                            NavigationLink(value: job.id) { JobRowView(row: JobList.row(job)) }
                        }
                    }
                }
                if model.jobs.isEmpty && !model.isLoading {
                    Text("No runs yet.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Runs")
            .navigationDestination(for: String.self) { id in
                if let job = model.jobs.first(where: { $0.id == id }) {
                    JobDetailView(model: model, job: job)
                }
            }
            .refreshable { await model.refresh() }
            .toolbar {
                Button("Sign out") { model.signOut() }
            }
            .overlay { if let e = model.error { Text(e).font(.callout).foregroundStyle(.red).padding() } }
        }
        .task {
            await model.refresh()
            await model.followLive()
        }
    }
}

struct JobRowView: View {
    let row: JobRow
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.id).font(.system(.subheadline, design: .monospaced))
                HStack(spacing: 6) {
                    Text(row.state)
                    Text("·"); Text(row.gpu)
                    Text("·"); Text(row.cost).monospacedDigit()
                    Text("·"); Text(row.elapsed).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                if let d = row.detail {
                    Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }
    var color: Color {
        switch row.tint {
        case .running: return .blue
        case .queued: return .orange
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

public struct JobDetailView: View {
    @ObservedObject var model: RunsViewModel
    let job: HostedJobStatus

    public var body: some View {
        List {
            Section("Run") {
                LabeledContent("State", value: job.state)
                LabeledContent("GPU", value: job.gpu ?? "—")
                LabeledContent("Attempt", value: "\(job.attempt ?? 1)")
                LabeledContent("Billed", value: JobList.row(job).elapsed)
                LabeledContent("Cost", value: JobList.row(job).cost)
                if let e = job.error {
                    LabeledContent("Error", value: JobList.errorExplanation(e))
                }
            }
            if let tail = job.thermo_tail, !tail.isEmpty {
                Section("Thermo") {
                    Text(tail.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            Section {
                if !job.isTerminal {
                    Button("Cancel run", role: .destructive) { Task { await model.cancel(job.id) } }
                }
                if job.state == "done" || job.state == "failed" {
                    Button("Save results…") { Task { await model.downloadResults(job.id) } }
                }
            }
        }
        .navigationTitle(job.id)
        #if os(iOS)
        .sheet(isPresented: Binding(get: { model.shareURL != nil },
                                    set: { if !$0 { model.shareURL = nil } })) {
            if let u = model.shareURL { ShareSheet(url: u) }
        }
        #endif
    }
}

#if os(iOS)
import UIKit

/// The results tarball goes to the system share sheet, which is what puts it in Files.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
