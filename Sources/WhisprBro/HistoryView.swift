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

    func refresh() {
        runSearch(query, debounce: false)
        Task { [store] in
            let total = await store?.count() ?? 0
            totalCount = total
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

/// The History window (spec §4/§11.6), rebuilt to the brand "App UI" mockup
/// (design §6g): a cream window with an echo-w title bar, a branded search
/// field, and a custom table with alternating cream rows + per-row actions on
/// hover. Search / re-insert / copy / clear are unchanged from before.
struct HistoryView: View {
    @StateObject private var model = HistoryViewModel()
    @State private var confirmingClear = false

    // Shared column widths (header + rows).
    private enum Col {
        static let when: CGFloat = 78, app: CGFloat = 74
        static let asr: CGFloat = 46, edit: CGFloat = 46, total: CGFloat = 54, actions: CGFloat = 80
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandSearchField(
                placeholder: "Search dictations",
                text: Binding(get: { model.query }, set: { model.queryChanged($0) })
            )
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            header
            Divider().overlay(Brand.ink.opacity(0.08))

            if model.records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.records.enumerated()), id: \.element.id) { i, r in
                            row(r, even: i.isMultiple(of: 2))
                        }
                    }
                }
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.raised)
        .onAppear { model.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            head("When", width: Col.when, align: .leading)
            head("App", width: Col.app, align: .leading)
            head("Text", width: nil, align: .leading)
            head("ASR", width: Col.asr, align: .trailing)
            head("Edit", width: Col.edit, align: .trailing)
            head("Total", width: Col.total, align: .trailing)
            Spacer().frame(width: Col.actions)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func head(_ text: String, width: CGFloat?, align: Alignment) -> some View {
        Text(text.uppercased())
            .font(Brand.mono(10, .medium)).tracking(1).foregroundStyle(Brand.metaMuted)
            .frame(width: width, alignment: align)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
    }

    // MARK: Row

    private func row(_ r: HistoryRecord, even: Bool) -> some View {
        HistoryRow(
            record: r, even: even, columns: (Col.when, Col.app, Col.asr, Col.edit, Col.total, Col.actions),
            onCopy: { copy(r.displayText) },
            onInsert: { reinsert(r.displayText) },
            onDelete: { model.delete(r) }
        )
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

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(model.totalCount) dictations")
                .font(Brand.mono(11.5)).foregroundStyle(Brand.mist)
            Spacer()
            Button("Clear all…") { confirmingClear = true }
                .buttonStyle(.plain)
                .font(Brand.sans(12.5, .medium)).foregroundStyle(Brand.signal)
                .disabled(model.totalCount == 0)
                .opacity(model.totalCount == 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Brand.ink.opacity(0.08)).frame(height: 1) }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmingClear) {
            Button("Clear all", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved dictation. It can't be undone.")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func reinsert(_ text: String) {
        // Yield focus back to the previously-frontmost app (don't close the whole
        // unified window), then paste. reinsertFromHistory's 0.35s delay +
        // secure-field guard are unchanged.
        NSApp.hide(nil)
        PipelineController.shared.reinsertFromHistory(text)
    }
}

/// A single history table row, with per-row actions revealed on hover.
private struct HistoryRow: View {
    let record: HistoryRecord
    let even: Bool
    let columns: (when: CGFloat, app: CGFloat, asr: CGFloat, edit: CGFloat, total: CGFloat, actions: CGFloat)
    let onCopy: () -> Void
    let onInsert: () -> Void
    let onDelete: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                .font(Brand.sans(12)).foregroundStyle(Brand.mist)
                .frame(width: columns.when, alignment: .leading)
            Text(record.appName ?? "—")
                .font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted).lineLimit(1)
                .frame(width: columns.app, alignment: .leading)
            Text(record.displayText)
                .font(Brand.sans(13)).foregroundStyle(Brand.ink).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            latency(record.asrMs, color: Brand.mist).frame(width: columns.asr, alignment: .trailing)
            latency(record.formatMs, color: Brand.mist).frame(width: columns.edit, alignment: .trailing)
            latency(record.totalMs, color: Brand.ink).frame(width: columns.total, alignment: .trailing)
            actions.frame(width: columns.actions, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(even ? Brand.paper : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.ink.opacity(0.06)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            iconButton("doc.on.doc", "Copy", onCopy)
            iconButton("text.cursor", "Insert into the frontmost app", onInsert)
            iconButton("trash", "Delete", onDelete)
        }
        .opacity(hover ? 1 : 0)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Brand.mist)
        }
        .buttonStyle(.plain).help(help)
    }

    private func latency(_ ms: Int?, color: Color) -> some View {
        Text(ms.map { "\($0)ms" } ?? "—")
            .font(Brand.mono(11)).foregroundStyle(color)
    }
}
