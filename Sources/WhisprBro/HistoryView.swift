import AppKit
import SwiftUI
import WhisprBroCore

/// Backing model for the History window: runs FTS searches off the main thread
/// and publishes results. A tiny debounce coalesces keystrokes. The store is
/// injected (defaults to the shared one) so the VM is unit-testable.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var records: [HistoryRecord] = []
    @Published private(set) var totalCount = 0

    private let store: HistoryStore?
    private var searchTask: Task<Void, Never>?

    init(store: HistoryStore? = HistoryStore.shared) {
        self.store = store
    }

    /// Reload results + the total count (on open and after a mutation).
    func refresh() {
        runSearch(query, debounce: false)
        Task { [store] in
            let total = await store?.count() ?? 0
            totalCount = total
        }
    }

    func queryChanged(_ newValue: String) {
        query = newValue
        runSearch(newValue, debounce: true) // count is query-independent — not refetched here
    }

    private func runSearch(_ q: String, debounce: Bool) {
        searchTask?.cancel()
        searchTask = Task { [store] in
            if debounce { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, let store else { return }
            let results = await store.search(q)
            guard !Task.isCancelled else { return }
            records = results
        }
    }

    func clearAll() {
        Task { [store] in
            await store?.deleteAll()
            refresh()
        }
    }

    func delete(_ record: HistoryRecord) {
        guard let id = record.id else { return }
        Task { [store] in
            await store?.delete(id: id)
            refresh()
        }
    }
}

/// The History window (spec §4 HistoryStore, §11.6): full-text search over past
/// dictations with per-stage latency columns visible, plus copy / re-insert.
struct HistoryView: View {
    @StateObject private var model = HistoryViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // NavigationStack hosts .searchable — on macOS the search field does
        // not render on a bare view.
        NavigationStack {
            VStack(spacing: 0) {
                Table(model.records) {
                    TableColumn("When") { r in
                        Text(r.createdAt, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("App") { r in Text(r.appName ?? "—").foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 90)
                    TableColumn("Text") { r in
                        Text(r.displayText).lineLimit(2).textSelection(.enabled)
                    }
                    .width(min: 200, ideal: 360)
                    TableColumn("ASR") { r in latency(r.asrMs) }.width(min: 44, ideal: 56)
                    TableColumn("Edit") { r in latency(r.formatMs) }.width(min: 44, ideal: 56)
                    TableColumn("Total") { r in latency(r.totalMs) }.width(min: 48, ideal: 60)
                    TableColumn("") { r in
                        HStack(spacing: 6) {
                            Button { copy(r.displayText) } label: { Image(systemName: "doc.on.doc") }
                                .help("Copy")
                            Button { reinsert(r.displayText) } label: { Image(systemName: "text.cursor") }
                                .help("Insert into the frontmost app")
                            Button { model.delete(r) } label: { Image(systemName: "trash") }
                                .help("Delete")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(min: 90, ideal: 96)
                }

                Divider()
                HStack {
                    Text("\(model.totalCount) dictations")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear all…", role: .destructive) { model.clearAll() }
                        .disabled(model.totalCount == 0)
                }
                .padding(8)
            }
            .navigationTitle("History")
            .searchable(text: Binding(
                get: { model.query },
                set: { model.queryChanged($0) }
            ), prompt: "Search dictations")
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func latency(_ ms: Int?) -> some View {
        Text(ms.map { "\($0)ms" } ?? "—")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Close the window (which returns focus + accessory policy), then paste
    /// into whatever app is now frontmost. The insertion path preserves the
    /// user's clipboard itself — do NOT pre-copy here or that snapshot is lost.
    private func reinsert(_ text: String) {
        dismiss()
        PipelineController.shared.reinsertFromHistory(text)
    }
}
