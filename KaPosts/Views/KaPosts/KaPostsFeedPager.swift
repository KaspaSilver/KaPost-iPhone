import SwiftUI

/// Following, Feed and Popular side by side, swiped between with a finger.
///
/// Not a `TabView` in page style: that one is a UIKit scroll view underneath, and the feed
/// redraws all the time while you swipe (an avatar or a name lands, a page of posts arrives).
/// A redraw mid-swipe could leave it parked between two pages, half of each on screen. Here the
/// position is always `selection` plus the finger's offset, and the offset is gesture state -
/// SwiftUI puts it back to zero when the touch ends or is taken away - so there is no
/// in-between position to get stuck in.
///
/// A touch commits to one direction from its first movement: an up-and-down drag is the list
/// scrolling and never moves the pages; a sideways one moves the pages. Let go past a third of
/// the width, or flick, and it moves one page; otherwise it settles back.
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

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                content
                    .frame(width: width)
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(selection) * width + drag.offset)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in
                        let t = value.translation
                        if state.horizontal == nil {
                            state.horizontal = abs(t.width) > abs(t.height)
                        }
                        guard state.horizontal == true else { return }
                        // Past the first or last page the pages give a little, then resist.
                        let pastEdge = (selection == 0 && t.width > 0)
                            || (selection == pageCount - 1 && t.width < 0)
                        state.offset = pastEdge ? t.width / 3 : t.width
                    }
                    .onEnded { value in
                        let t = value.translation
                        guard abs(t.width) > abs(t.height) else { return }
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
