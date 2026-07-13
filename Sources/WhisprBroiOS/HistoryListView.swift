import SwiftUI
import UIKit
import WhisprBroCore

/// Backing model for the History tab: FTS searches off the main thread with a
/// keystroke debounce (the iOS twin of the macOS HistoryViewModel).
@MainActor
final class HistoryListModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var records: [HistoryRecord] = []
    @Published private(set) var totalCount = 0

    private let store: HistoryStore?
    private var searchTask: Task<Void, Never>?

    init(store: HistoryStore? = HistoryStore.shared) {
        self.store = store
    }

    func refresh() {
        runSearch(query, debounce: false)
        Task { [store] in
            totalCount = await store?.count() ?? 0
        }
    }

    func queryChanged(_ newValue: String) {
        query = newValue
        runSearch(newValue, debounce: true)
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

/// The History tab: searchable local dictation log (FTS5), swipe to delete,
/// tap-row copy, clear-all with confirmation.
struct HistoryListView: View {
    @StateObject private var model = HistoryListModel()
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if model.records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.records) { record in
                        HistoryListRow(record: record)
                            .listRowBackground(Brand.raised)
                    }
                    .onDelete { offsets in
                        for i in offsets { model.delete(model.records[i]) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Brand.paper.ignoresSafeArea())
        .navigationTitle("History")
        .searchable(
            text: Binding(get: { model.query }, set: { model.queryChanged($0) }),
            prompt: "Search dictations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear all…") { confirmingClear = true }
                    .font(Brand.sans(13, .medium)).foregroundStyle(Brand.signal)
                    .disabled(model.totalCount == 0)
            }
        }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmingClear) {
            Button("Clear all", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved dictation. It can't be undone.")
        }
        .onAppear { model.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            EchoWMark(color: Brand.mist).frame(width: 40, height: 27)
            Text(model.query.isEmpty ? "No dictations yet" : "No matches")
                .font(Brand.sans(14, .medium)).foregroundStyle(Brand.bodyMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// One history row: timestamp + latency meta line, transcript body, and a
/// copy/share context menu.
private struct HistoryListRow: View {
    let record: HistoryRecord
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(Brand.mono(11)).foregroundStyle(Brand.mist)
                Spacer()
                if copied {
                    Text("COPIED")
                        .font(Brand.mono(10, .medium)).tracking(1).foregroundStyle(Brand.mist)
                } else if let total = record.totalMs {
                    Text("\(total)ms")
                        .font(Brand.mono(11)).foregroundStyle(Brand.metaMuted)
                }
            }
            Text(record.displayText)
                .font(Brand.sans(14)).foregroundStyle(Brand.ink)
                .lineLimit(4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { copy() }
        .contextMenu {
            Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
            ShareLink(item: record.displayText)
        }
    }

    private func copy() {
        UIPasteboard.general.string = record.displayText
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
