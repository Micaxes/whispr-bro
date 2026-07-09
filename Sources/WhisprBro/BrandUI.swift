import SwiftUI
import WhisprBroCore

/// Reusable branded window components (design doc §6f/§6g). These reproduce the
/// "App UI" mockups natively so Settings and History match the brand: cream
/// full-bleed window, echo-w title bar, tab rail, radio rows, cards, table.

/// Cream window shell with a centered echo-w title bar. Pairs with
/// `.windowStyle(.hiddenTitleBar)` so the OS traffic lights float at top-left
/// over the header (which stays clear on the left for them).
struct BrandWindow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            BrandTitleBar(title: title)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Brand.raised)
    }
}

struct BrandTitleBar: View {
    let title: String
    var body: some View {
        ZStack {
            HStack(spacing: 11) {
                EchoWMark(color: Brand.ink).frame(width: 34, height: 22)
                Text(title).font(Brand.sans(15, .semibold)).foregroundStyle(Brand.ink)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(Brand.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Brand.ink.opacity(0.08)).frame(height: 1)
        }
    }
}

/// Mono, uppercase, wide-tracked section label (11px `.18em`).
struct BrandSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(10.5, .medium))
            .tracking(1.9)
            .foregroundStyle(Brand.mist)
    }
}

/// Muted body caption (Archivo 12, `#6B6558`).
struct BrandCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A selectable radio row (design §6f): selected = paper fill + 1.5px ink border
/// + thick ink radio; unselected = raised + faint border + hollow radio.
struct BrandRadioRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Brand.ink : Color(hex: 0xB7AC94), lineWidth: selected ? 5 : 1.5)
                    .background(Circle().fill(Brand.paper))
                    .frame(width: 17, height: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Brand.sans(14, .semibold)).foregroundStyle(Brand.ink)
                    if let subtitle {
                        Text(subtitle).font(Brand.sans(12.5)).foregroundStyle(Brand.bodyMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Brand.paper : Brand.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Brand.ink : Brand.ink.opacity(0.10), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A tab-rail item (design §6f): active = ink fill + paper text + square dot;
/// inactive = muted text + hollow dot, cream hover.
struct BrandTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if selected {
                        RoundedRectangle(cornerRadius: 2).fill(Brand.paper)
                    } else {
                        Circle().fill(Color(hex: 0xB7AC94))
                    }
                }
                .frame(width: 7, height: 7)
                Text(title)
                    .font(Brand.sans(13, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Brand.paper : Brand.bodyMuted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Brand.ink : (hover ? Color(hex: 0xEFE8DA) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The "● offline / 0 packets sent" card at the bottom of the Settings rail.
struct OfflineCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Brand.ink).frame(width: 6, height: 6)
                Text("offline").font(Brand.mono(10.5)).foregroundStyle(Brand.bodyMuted)
            }
            Text("0 packets sent").font(Brand.mono(10)).foregroundStyle(Brand.metaMuted)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.paper))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.ink.opacity(0.07), lineWidth: 1))
    }
}

/// Search field (design §6g): paper fill, mono placeholder, magnifier.
struct BrandSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.mist)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Brand.metaMuted))
                .textFieldStyle(.plain)
                .font(Brand.mono(13))
                .foregroundStyle(Brand.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Brand.paper))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Brand.ink.opacity(0.10), lineWidth: 1))
    }
}

/// A pill/keycap-style key label (mono), for the shortcut recorder button face.
struct BrandKeycap: View {
    let text: String
    let active: Bool
    var body: some View {
        Text(text)
            .font(Brand.mono(13, .medium))
            .foregroundStyle(active ? Brand.paper : Brand.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Brand.ink : Brand.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Brand.ink.opacity(0.16), lineWidth: 1)
            )
    }
}

/// A grouped card container (raised surface, hairline border, 20px radius).
struct BrandCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.ink.opacity(0.10), lineWidth: 1))
    }
}
