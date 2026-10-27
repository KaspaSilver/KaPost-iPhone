import SwiftUI
import UIKit

/// The feed's hamburger menu: a card that slides out from the left over nearly the whole screen
/// (the dock included), with the feed dimmed in the strip beside it. Tap that strip, tap the
/// close button or drag the card back to the left to close it.
///
/// It is a full-screen cover so it can sit above the dock; `KaPostsView` presents it through
/// `kaPostsPresent` (no cover animation), and the card draws its own slide over the picture of
/// the screen that `kaPostsPresent` took. Picking a row hands the item back through `onSelect`
/// and closes the card; the feed opens the item's screen once the card is gone, since a cover
/// cannot present the next one while it is still on screen.
struct KaPostsFeedDrawer: View {
    let items: [KaPostsView.SideMenuItem]
    let onSelect: (KaPostsView.SideMenuItem) -> Void
    /// Dismisses the cover; the card has already slid out.
    let onClose: () -> Void

    @ObservedObject private var notifCenter = KaPostsNotificationCenter.shared
    @State private var shown = false
    @State private var dragOffset: CGFloat = 0
    @State private var closing = false
    private let backdrop = KaPostsSlideSnapshot.image

    private let slideDuration: TimeInterval = 0.22

    var body: some View {
        GeometryReader { geo in
            // Most of the screen, with enough of the feed left showing to tap it closed.
            let panelWidth = min(geo.size.width * 0.86, 440)
            let progress = shown ? 1 + min(0, dragOffset) / panelWidth : 0
            ZStack(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityElement()
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { close() }
                panel
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(
                        DrawerCardShape(radius: 24)
                            .fill(Color(.systemBackground))
                            .shadow(color: .black.opacity(0.25), radius: 12, x: 4, y: 0)
                            .ignoresSafeArea()
                    )
                    .offset(x: shown ? min(0, dragOffset) : -panelWidth - 16)
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard !closing else { return }
                        dragOffset = min(0, value.translation.width)
                    }
                    .onEnded { value in
                        guard !closing else { return }
                        if -value.translation.width > panelWidth / 3
                            || value.predictedEndTranslation.width < -panelWidth / 2 {
                            close()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
                        }
                    }
            )
            .background(backdropLayer(dim: 0.45 * progress))
        }
        .accessibilityAction(.escape) { close() }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { shown = true }
        }
    }

    private func backdropLayer(dim: Double) -> some View {
        ZStack {
            if let backdrop {
                // Stretched to the screen, not scaled to fill: the picture IS the screen, and a
                // fill let the layout's proposal blow it up a few percent, so the strip of feed
                // beside the card no longer lined up with the real one.
                Image(uiImage: backdrop)
                    .resizable()
            } else {
                Color(.systemBackground)
            }
            Color.black.opacity(dim)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("KaPost")
                    .font(.largeTitle.weight(.bold))
                Spacer(minLength: 0)
                Button {
                    Haptics.selection()
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.scaled(size: 17, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close menu")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 8)

            ForEach(items) { item in
                row(item)
            }

            Spacer(minLength: 0)
        }
    }

    private func row(_ item: KaPostsView.SideMenuItem) -> some View {
        let unseen = item == .notifications ? notifCenter.unseenCount : 0
        return Button {
            Haptics.impact(.light)
            onSelect(item)
            close()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: item.icon)
                    .font(.scaled(size: 22, weight: .semibold))
                    .foregroundColor(Color("AccentColor"))
                    .frame(width: 30)
                Text(verbatim: item.rawValue)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
                if unseen > 0 {
                    Text(notifCenter.badgeText)
                        .font(.scaled(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(unseen > 0 ? "\(item.rawValue), \(unseen) unseen" : item.rawValue))
    }

    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.easeIn(duration: slideDuration)) {
            shown = false
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + slideDuration) { onClose() }
    }
}

/// The card's outline: square on the left, where it meets the screen edge, rounded on the
/// right. (`UnevenRoundedRectangle` is iOS 17; KaPosts runs on 16.)
private struct DrawerCardShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topRight, .bottomRight],
            cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
    }
}
