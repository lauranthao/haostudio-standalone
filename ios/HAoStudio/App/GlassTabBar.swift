// HAo Studio 2.0 — floating glass tab bar.
//
// Ported from the Kumone reference
// (~/workspace/research/kumone/Sources/Kumone/Features/GlassTabBar.swift):
// full-height glass capsule (56pt content + 4pt inset = 64pt), sliding
// selection pill, draggable pill that switches tabs live, settle spring
// response 0.35 / dampingFraction 0.82.
//
// Differences from Kumone, per chen's rules:
// - Selected-item colour is BLACK (light) / white (dark) — `tabSelected`
//   from the theme palette — NOT Kumone's red, NOT the theme accent.
// - Unselected items are primary at 80% opacity, as in Kumone.
// - The bar itself uses the shared `haoGlassCapsule()` treatment
//   (native .glassEffect on iOS 26+, regular material below), so the
//   iOS 17–25 fallback and the iOS 26+ path stay one component.

import SwiftUI

/// One tab in the floating bar.
struct GlassTabBarItem: Identifiable {
    let tab: HaoTab
    let title: String
    let icon: String

    var id: HaoTab { tab }
}

struct GlassTabBar: View {
    let items: [GlassTabBarItem]
    @Binding var selection: HaoTab
    /// Called when the already-selected tab is tapped again. Foundation:
    /// no-op (placeholder pages have nothing to scroll to top yet).
    var onReselect: (HaoTab) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.haoTheme) private var theme

    /// Finger x (in content space) while actively dragging the pill; nil at rest.
    @State private var dragX: CGFloat?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let count = max(items.count, 1)
            let cellW = geo.size.width / CGFloat(count)
            let selectedIndex = items.firstIndex { $0.tab == selection } ?? 0
            let restX = cellW * (CGFloat(selectedIndex) + 0.5)
            let pillX = isDragging
                ? min(max(dragX ?? restX, cellW / 2), geo.size.width - cellW / 2)
                : restX

            ZStack(alignment: .leading) {
                selectionPill
                    .frame(width: cellW - 8, height: HaoLayout.tabBarContentHeight)
                    .position(x: pillX, y: geo.size.height / 2)

                HStack(spacing: 0) {
                    ForEach(items) { item in
                        itemLabel(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(cellW: cellW, count: count))
        }
        .frame(height: HaoLayout.tabBarContentHeight)
        .padding(HaoLayout.tabBarInnerInset)
        .haoGlassCapsule()
    }

    private func itemLabel(_ item: GlassTabBarItem) -> some View {
        let isSelected = selection == item.tab
        return VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 23, weight: .semibold))
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
        }
        // Selected: black (light) / white (dark) — chen's rule, not red.
        // Unselected: primary at 80%.
        .foregroundStyle(isSelected ? theme.tabSelected : Color.primary.opacity(0.8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The sliding indicator — a bar-height capsule with a faint tint
    /// (black @ 7.5% in light / white @ 10% in dark), as in Kumone.
    private var selectionPill: some View {
        Capsule(style: .continuous)
            .fill(colorScheme == .dark
                  ? Color.white.opacity(0.10)
                  : Color.black.opacity(0.075))
    }

    private func index(for x: CGFloat, cellW: CGFloat, count: Int) -> Int {
        min(max(Int(x / cellW), 0), count - 1)
    }

    private func dragGesture(cellW: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Wait for a clear horizontal intent before "lifting" the pill,
                // so a plain tap slides rather than teleporting to the finger.
                if !isDragging && abs(value.translation.width) < 8 { return }
                isDragging = true
                dragX = value.location.x
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if tab != selection { selection = tab }   // live switch, pill tracks finger
            }
            .onEnded { value in
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if isDragging {
                    withAnimation(HaoLayout.settleSpring) { selection = tab; dragX = nil }
                } else if tab == selection {
                    onReselect(tab)
                } else {
                    withAnimation(HaoLayout.settleSpring) { selection = tab }
                }
                isDragging = false
            }
    }
}
