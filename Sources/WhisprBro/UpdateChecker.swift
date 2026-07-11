import AppKit
import Foundation
import SwiftUI
import WhisprBroCore

/// Drives the on-by-default "new version available" signal WITHOUT the app ever
/// touching the network.
///
/// The app binary carries zero networking code (enforced by audit-offline.sh,
/// net-tripwire, and the tcpdump capture). So the actual GitHub check runs in a
/// SEPARATE short-lived process — the bundled `whispr-update-check.sh` — which
/// this model launches with `Process` (posix_spawn: not a networking call) on a
/// daily throttle unless the user has turned checks off (they are ON BY DEFAULT;
/// a one-time non-blocking notice discloses this). The helper writes
/// `update-state.json`; this model then merely *reads that file* and compares
/// tags. Nothing here opens a connection.
@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    /// The user's standing choice for the daily background check. Update checks
    /// are ON BY DEFAULT (`nil` = never touched = on); the user can turn them off.
    /// A one-time, non-blocking notice discloses this — it never gates the app.
    enum Preference: String { case on, off }

    @Published private(set) var availability: UpdateAvailability = .unknown
    /// True until the user has acknowledged the one-time "updates are on" notice.
    @Published var showDisclosure = false
    @Published private(set) var isChecking = false

    /// The running build's version, shown in the menu + Settings and compared
    /// against the latest release tag.
    let currentVersion: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"

    private let defaults = UserDefaults.standard
    private let prefKey = "updateCheckPreference"
    private let lastSpawnKey = "updateLastSpawnEpoch"
    private let dismissedTagKey = "updateDismissedTag"
    private let disclosureKey = "updateDisclosureShown"
    private let minInterval: TimeInterval = 24 * 60 * 60   // once a day
    private var timer: Timer?
    /// Set when the user turns checks off, so a helper that is already IN FLIGHT
    /// can't re-surface a result after the user asked for quiet. Cleared by any
    /// explicit request to show results (turning on, or a manual "Check now").
    private var suppressResults = false

    private init() {}

    var preference: Preference? {
        defaults.string(forKey: prefKey).flatMap(Preference.init)
    }

    /// On by default — enabled unless the user has explicitly turned it off.
    var autoCheckEnabled: Bool { preference != .off }

    /// Show the update pill only for an available version the user hasn't waved
    /// away (dismissal is per-tag, so a newer release re-surfaces it).
    var showUpdatePill: Bool {
        guard case .available(let tag, _) = availability else { return false }
        return defaults.string(forKey: dismissedTagKey) != tag
    }

    // MARK: Lifecycle

    /// Called once at launch. When checks are on, reflects any prior result and
    /// fires a throttled background check; when off, stays quiet (no disk read,
    /// so a stale state file never re-surfaces the pill across launches). Shows
    /// the one-time disclosure notice if it hasn't been seen.
    func startup() {
        showDisclosure = !defaults.bool(forKey: disclosureKey) && autoCheckEnabled
        // Re-read + re-check a few times a day while the app is alive (tick() is a
        // no-op when checks are off; the spawn is throttled to once per interval).
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        guard autoCheckEnabled else { return }
        reloadFromDisk()
        maybeSpawn()
    }

    private func tick() {
        guard autoCheckEnabled else { return }
        reloadFromDisk()
        maybeSpawn()
    }

    // MARK: User actions

    /// From the disclosure notice / Settings toggle. Recording either choice also
    /// marks the one-time notice as seen. Turning OFF immediately clears any
    /// surfaced result so the pill / menu item / Settings banner all disappear.
    func setAutoCheck(_ on: Bool) {
        defaults.set((on ? Preference.on : Preference.off).rawValue, forKey: prefKey)
        defaults.set(true, forKey: disclosureKey)
        showDisclosure = false
        if on { forceCheck() } else { suppressResults = true; availability = .unknown }
    }

    /// Dismiss the one-time notice, leaving auto-checks on (the default).
    func acknowledgeDisclosure() {
        defaults.set(true, forKey: disclosureKey)
        showDisclosure = false
    }

    /// A manual, explicitly user-initiated one-shot check. Always allowed — it is
    /// the user asking, right now — regardless of the daily auto-check preference.
    func checkNow() {
        forceCheck()
    }

    /// Open the release page in the user's browser (the app never downloads).
    func openReleasePage() {
        let target: String
        if case .available(_, let url) = availability { target = url }
        else { target = UpdateEndpoint.releasesLatestURL }
        if let url = URL(string: target) { NSWorkspace.shared.open(url) }
    }

    /// Hide the pill for the current version until a newer one appears.
    func dismissPill() {
        guard case .available(let tag, _) = availability else { return }
        defaults.set(tag, forKey: dismissedTagKey)
        objectWillChange.send()
    }

    // MARK: Internals

    private func forceCheck() {
        suppressResults = false                       // the user explicitly wants a result
        defaults.removeObject(forKey: lastSpawnKey)   // bypass the daily throttle
        maybeSpawn()
    }

    /// Spawn the helper if the throttle window has elapsed. `Process`/posix_spawn
    /// launches a distinct process — no networking symbol enters this binary.
    private func maybeSpawn() {
        guard !isChecking else { return }   // never run two helpers at once
        let last = defaults.double(forKey: lastSpawnKey)
        let now = Date().timeIntervalSince1970
        if last > 0, now - last < minInterval { return }
        guard let script = Self.helperScriptURL else { return }

        isChecking = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path, UpdateEndpoint.repo, Paths.updateStateFile.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { _ in
            Task { @MainActor in
                self.isChecking = false
                self.reloadFromDisk()
            }
        }
        // Only consume the daily throttle once the helper actually launched — a
        // failed spawn shouldn't block the next check for 24h.
        do {
            try proc.run()
            defaults.set(now, forKey: lastSpawnKey)
        } catch {
            isChecking = false
        }
    }

    private func reloadFromDisk() {
        // Respect a "turn off" that landed while a helper was still in flight —
        // don't let its late result re-surface the pill (regression guard).
        guard !suppressResults else { return }
        let state = UpdateState.load(from: Paths.updateStateFile)
        availability = UpdateStatus.evaluate(current: currentVersion, state: state)
    }

    /// The bundled helper (`Contents/Resources/whispr-update-check.sh`). Absent
    /// when running un-bundled via `swift run`, in which case checks no-op.
    static var helperScriptURL: URL? {
        Bundle.main.url(forResource: "whispr-update-check", withExtension: "sh")
    }
}

// MARK: - The bottom-left pill (Claude-style toast)

/// A small brand card anchored bottom-left of the main window. Shows the one-time
/// disclosure notice (checks are already on), then an "update available" prompt
/// with a Download button that opens the release page in the browser.
struct UpdatePillOverlay: View {
    @ObservedObject var update: UpdateModel

    var body: some View {
        Group {
            if update.showDisclosure {
                disclosureCard
            } else if update.showUpdatePill, case .available(let tag, _) = update.availability {
                availableCard(tag: tag)
            }
        }
        .padding(16)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: update.showDisclosure)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: update.showUpdatePill)
    }

    // One-time, non-blocking notice: update checks are on by default, here's how
    // to manage them, and here's what "check" actually means for this app.
    private var disclosureCard: some View {
        pillCard {
            HStack(spacing: 10) {
                EchoWMark(color: Brand.ink).frame(width: 22, height: 15)
                Text("Update checks are on").font(Brand.sans(14, .semibold)).foregroundStyle(Brand.ink)
                Spacer(minLength: 0)
            }
            Text("whispr·bro looks for a newer version once a day. The app itself never connects — a separate helper does. Manage this anytime in Settings.")
                .font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                pillButton("OK", filled: true) { update.acknowledgeDisclosure() }
                pillButton("Turn off", filled: false) { update.setAutoCheck(false) }
            }
        }
    }

    // "New version available."
    private func availableCard(tag: String) -> some View {
        pillCard {
            HStack(spacing: 10) {
                Circle().fill(Brand.signal).frame(width: 8, height: 8)
                Text("Update available").font(Brand.sans(14, .semibold)).foregroundStyle(Brand.ink)
                Spacer(minLength: 0)
                Button { update.dismissPill() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.mist)
                }
                .buttonStyle(.plain)
            }
            Text("\(tag) is out — you're on \(update.currentVersion).")
                .font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                pillButton("Download", filled: true) { update.openReleasePage() }
            }
        }
    }

    // MARK: pieces

    @ViewBuilder private func pillCard(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .padding(14)
            .frame(width: 296, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.ink.opacity(0.12), lineWidth: 1))
            .shadow(color: Brand.ink.opacity(0.16), radius: 16, x: 0, y: 6)
    }

    private func pillButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Brand.sans(12, .semibold))
                .foregroundStyle(filled ? Brand.paper : Brand.ink)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(filled ? Brand.ink : Brand.raised))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Brand.ink.opacity(filled ? 0 : 0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
