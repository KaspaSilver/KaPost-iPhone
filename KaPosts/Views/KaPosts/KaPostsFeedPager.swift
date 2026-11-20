import SwiftUI

/// Following, Feed and Popular side by side, swiped between with a finger. The Wallet's tabs
/// (History, UTXOs, Domains) use it too.
///
/// Not a `TabView` in page style: that one is a UIKit scroll view underneath, and the feed
/// redraws all the time while you swipe (an avatar or a name lands, a page of posts arrives).
/// A redraw mid-swipe could leave it parked between two pages, half of each on screen. Here the
/// position is always `selection` plus the finger's offset, and the offset is gesture state -
/// SwiftUI puts it back to zero when the touch ends or is taken away - so there is no
/// in-between position to get stuck in.
///
/// A touch commits to one direction from its first movement and keeps it until the finger lifts:
/// an up-and-down drag is the list scrolling and never moves the pages; a clearly sideways one
/// (more than 1.3 times as wide as tall, `sidewaysBias`) moves the pages, and the lists stop
/// scrolling for the rest of that touch (`.scrollDisabled`), so the feed underneath doesn't drift
/// up or down while you change pages. Let go past a third of the width, or flick, and it moves one
/// page; otherwise it settles back. The end of a sideways touch counts by the direction it locked
/// to, not where the finger drifted.
///
/// `content` is the pages in order (a `ForEach`); each is laid out at the full width.
struct KaPostsFeedPager<Content: View>: View {
    let pageCount: Int
    @Binding var selection: Int
    @ViewBuilder let content: Content

    private struct Drag: Equatable {
        var horizontal: Bool?
        var offset: CGFloat = 0
    }

    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.9)))
    private var drag = Drag()

    /// How much wider than tall a first movement must be to count as sideways: a slightly
    /// diagonal scroll stays a scroll.
    private static var sidewaysBias: CGFloat { 1.3 }

    /// The current touch's locked direction, kept past the gesture state's reset so the end of the
    /// touch reads the same lock (nil between touches).
    @State private var touchSideways: Bool?
    /// Where that touch began: a touch the list's own scroll took over never reaches `onEnded`, so a
    /// new start point is what marks a new touch.
    @State private var touchStart: CGPoint?

    private static func isSideways(_ t: CGSize) -> Bool {
        abs(t.width) > abs(t.height) * sidewaysBias
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                content
                    .frame(width: width)
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(selection) * width + drag.offset)
            // A sideways touch owns the screen: the lists hold still until it ends.
            .scrollDisabled(drag.horizontal == true)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .updating($drag) { value, state, _ in
                        let t = value.translation
                        if state.horizontal == nil {
                            state.horizontal = Self.isSideways(t)
                        }
                        guard state.horizontal == true else { return }
                        // Past the first or last page the pages give a little, then resist.
                        let pastEdge = (selection == 0 && t.width > 0)
                            || (selection == pageCount - 1 && t.width < 0)
                        state.offset = pastEdge ? t.width / 3 : t.width
                    }
                    .onChanged { value in
                        if touchStart != value.startLocation {
                            touchStart = value.startLocation
                            touchSideways = Self.isSideways(value.translation)
                        }
                    }
                    .onEnded { value in
                        let t = value.translation
                        let sideways = touchSideways ?? Self.isSideways(t)
                        touchSideways = nil
                        touchStart = nil
                        guard sideways else { return }
                        let flick = value.predictedEndTranslation.width
                        var next = selection
                        if (t.width < -width / 3 || flick < -width / 2), selection < pageCount - 1 {
                            next += 1
                        } else if (t.width > width / 3 || flick > width / 2), selection > 0 {
                            next -= 1
                        }
                        guard next != selection else { return }
                        Haptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            selection = next
                        }
                    }
            )
        }
    }
}
