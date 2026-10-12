import SwiftUI

// The thumb menu of the chat, as on Android: the + key at the left of the
// field opens it above the key. A tap opens it, and a tap on an item runs
// the item. A hold opens it at once: the thumb slides to an item, the item
// lights up, and the release runs it. A release on no item keeps the menu
// open. The items nearest the thumb lead to the other tabs, so the chat
// needs no tab bar.

/// The coordinate space of the chat, where the key and the items of the menu have their frames.
let thumbMenuSpace = "thumbMenu"

/// An item of the thumb menu. `name` is what VoiceOver reads.
struct ThumbItem: Identifiable {
    let icon: String
    let label: String
    let name: String
    var enabled = true
    let run: () -> Void

    var id: String { label }
}

/// A group of items with a title. `wide` items take a row of 2, with the icon before the label.
struct ThumbSection: Identifiable {
    let title: String
    let items: [ThumbItem]
    var wide = false

    var id: String { title }
}

/// The state of the thumb menu. `held` is true while the finger that opened
/// the menu stays down, and `hover` is the label of the item under it.
@MainActor
@Observable
final class ThumbMenu {
    private(set) var open = false
    private(set) var held = false
    var hover: String?
    /// Counts the holds, so that each hold gives 1 tap of the iPhone.
    private(set) var holds = 0
    /// The frame of the + key and of each item in `thumbMenuSpace`.
    var key: CGRect = .zero
    var frames: [String: CGRect] = [:]
    @ObservationIgnored var items: [String: ThumbItem] = [:]

    func show(hold: Bool) {
        open = true
        held = hold
        hover = nil
        if hold { holds += 1 }
    }

    func close() {
        open = false
        held = false
        hover = nil
    }

    /// The label of the item at `point` that the user can select, or nil.
    func item(at point: CGPoint) -> String? {
        guard let hit = frames.first(where: { $0.value.contains(point) })?.key, items[hit]?.enabled == true else { return nil }
        return hit
    }

    /// Ends a hold: the item under the finger runs, or the menu stays open for a tap.
    func release() {
        let item = hover.flatMap { items[$0] }.flatMap { $0.enabled ? $0 : nil }
        held = false
        hover = nil
        if let item {
            close()
            item.run()
        }
    }
}

/// How long a press waits before it opens the menu for the thumb.
private let thumbHold: Duration = .milliseconds(350)

/// The + key of the dock. A tap opens the menu, and a hold opens it for the thumb.
struct ThumbKey: View {
    let menu: ThumbMenu
    @Environment(\.tn) private var tn
    @State private var press: Task<Void, Never>?
    @State private var down = false
    /// True while the finger is down. SwiftUI resets it also when the system cancels the touch, which calls no onEnded.
    @GestureState private var pressing = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(menu.open ? tn.onAccent : tn.text)
            .frame(width: 48, height: 48)
            .background(Circle().fill(menu.open ? tn.accent : tn.line))
            .contentShape(Circle())
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { menu.key = g.frame(in: .named(thumbMenuSpace)) }
                    .onChange(of: g.frame(in: .named(thumbMenuSpace))) { _, f in menu.key = f }
            })
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(thumbMenuSpace))
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { value in
                        if !down {
                            down = true
                            press = Task { @MainActor in
                                try? await Task.sleep(for: thumbHold)
                                if !Task.isCancelled && down { menu.show(hold: true) }
                            }
                        }
                        if menu.held { menu.hover = menu.item(at: value.location) }
                    }
                    .onEnded { _ in
                        down = false
                        press?.cancel()
                        if menu.held { menu.release() } else { menu.show(hold: false) }
                    }
            )
            // A cancelled touch ends the hold as a release does. A normal end calls onEnded, which clears `down`
            // first, so the check waits 1 turn of the main actor and acts only for a cancel.
            .onChange(of: pressing) { _, now in
                guard !now else { return }
                Task { @MainActor in
                    guard down else { return }
                    down = false
                    press?.cancel()
                    if menu.held { menu.release() }
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: menu.holds)
            .sensoryFeedback(.selection, trigger: menu.hover) { _, new in new != nil }
            .accessibilityElement()
            .accessibilityLabel("Menu")
            .accessibilityHint("Files, the camera, and the other tabs")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { menu.show(hold: false) }
    }
}

/// The thumb menu over the chat, when it is open. A card above the + key
/// holds the `sections`, with the last section nearest the thumb. A tap on
/// the scrim closes it.
struct ThumbMenuOverlay: View {
    let menu: ThumbMenu
    let sections: [ThumbSection]
    @Environment(\.tn) private var tn

    var body: some View {
        // The items run the actions of this render, also when the label stays the same.
        let _ = menu.items = Dictionary(sections.flatMap(\.items).map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        GeometryReader { g in
            if menu.open {
                ZStack(alignment: .bottomLeading) {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { menu.close() }
                        .accessibilityLabel("Close the menu")
                        .accessibilityAddTraits(.isButton)
                    // The card ends 10 points above the + key. On a short screen it scrolls, so it never covers the key.
                    ViewThatFits(in: .vertical) {
                        card
                        ScrollView { card }
                    }
                    .frame(maxHeight: max(0, menu.key.minY - 10 - 8), alignment: .bottom)
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(0, g.size.height - menu.key.minY + 10))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: menu.open)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { s in
                Text(s.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tn.sub)
                    .padding(.leading, 6)
                    .padding(.top, 2)
                    .accessibilityAddTraits(.isHeader)
                let columns = s.wide ? 2 : 3
                let rows = stride(from: 0, to: s.items.count, by: columns).map { Array(s.items[$0..<min($0 + columns, s.items.count)]) }
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(rows[r]) { item in cell(item, wide: s.wide) }
                        // A short last row keeps the width of the columns.
                        ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(shape.fill(tn.bg))
        .overlay(shape.strokeBorder(tn.lineHi))
    }

    /// An item. It lights up while the thumb is on it.
    private func cell(_ item: ThumbItem, wide: Bool) -> some View {
        let lit = menu.hover == item.label
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            menu.close()
            item.run()
        } label: {
            Group {
                if wide {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).font(.system(size: 18)).foregroundStyle(tn.accent)
                        Text(item.label).font(.subheadline.weight(.semibold)).foregroundStyle(lit ? tn.accent : tn.text).lineLimit(1)
                    }
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon).font(.system(size: 20)).foregroundStyle(tn.accent)
                        Text(item.label).font(.caption.weight(.medium)).foregroundStyle(lit ? tn.accent : tn.text).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: wide ? 56 : 72)
            .background(shape.fill(lit ? tn.accentTile : tn.tile))
            .overlay(shape.strokeBorder(lit ? tn.accent : tn.line))
            .contentShape(shape)
            .scaleEffect(lit ? 1.05 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: lit)
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled || menu.held)
        .opacity(item.enabled ? 1 : TiledMetrics.disabledAlpha)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { menu.frames[item.label] = g.frame(in: .named(thumbMenuSpace)) }
                .onChange(of: g.frame(in: .named(thumbMenuSpace))) { _, f in menu.frames[item.label] = f }
        })
        .accessibilityLabel(item.name)
    }
}

/// The dots of the 3 tabs in a strip under the status bar, in the same
/// place on each tab. Chat has no tab bar, so they show that a swipe to the
/// side leads to Control and Computers. A tap on a dot opens that tab.
struct SwipeDots: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { t in
                let on = t == model.tab
                Button {
                    model.select(t)
                } label: {
                    Capsule()
                        .fill(on ? tn.accent : tn.dim)
                        .frame(width: on ? 18 : 6, height: 6)
                        .frame(width: 28, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tab \((AppTab.allCases.firstIndex(of: model.tab) ?? 0) + 1) of 3. Swipe to the side for the other tabs.")
    }
}

/// A swipe to the side moves to the next or the previous tab. With
/// `edges`, the swipe must start near the left or the right edge, so that
/// it does not take the swipes of a row that scrolls to the side.
struct TabSwipe: ViewModifier {
    @Environment(AppModel.self) private var model
    var edges = false
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { _, w in width = w }
            })
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .local)
                    .onEnded { v in
                        let dx = v.translation.width
                        let dy = v.translation.height
                        guard abs(dx) > 90, abs(dx) > 2.5 * abs(dy), (v.predictedEndTranslation.width > 0) == (dx > 0) else { return }
                        if edges {
                            let x = v.startLocation.x
                            guard x < 44 || x > width - 44 else { return }
                        }
                        let all = AppTab.allCases
                        guard let i = all.firstIndex(of: model.tab) else { return }
                        let next = dx < 0 ? i + 1 : i - 1
                        guard all.indices.contains(next) else { return }
                        model.select(all[next])
                    }
            )
    }
}

extension View {
    /// A swipe to the side moves between the tabs, see `TabSwipe`.
    func tabSwipe(edges: Bool = false) -> some View { modifier(TabSwipe(edges: edges)) }
}
