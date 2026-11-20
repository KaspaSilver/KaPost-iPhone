import SwiftUI
import UIKit

/// Rich link-preview card for a link in a post (`KaPostCellView`) or a Public Chats message
/// (`PublicChatChannelView`) - mirrors iMessage. Made only for a poster or sender with a `.kachat`
/// name and a link to KaChat's site or an allowed site (`KaPostLinkPreviewPolicy`). Renders nothing
/// while the fetch is in flight (or `loadingHeight` of empty card) and nothing if no preview data
/// was found and no [fallbackText] was given, rather than a placeholder that could flash or look
/// broken.
struct LinkPreviewCardView: View {
    let url: URL
    /// The owning message's transaction id, for the "View in Explorer" long-press action -
    /// matches every other bubble type's identical action (`MessageBubbleView`'s
    /// `settingsViewModel.settings.kaspaExplorer.txURL(for:)` call sites).
    let txId: String
    /// Non-nil only when this card is standing in for the *entire* message (nothing but a bare
    /// link, no separate text bubble shown alongside it) - shown as a plain tappable-link bubble
    /// if the fetch finds no preview data, so the message doesn't render as nothing at all. Nil
    /// when used alongside a real text bubble, where showing nothing on failure is correct since
    /// the message's own text is already visible.
    var fallbackText: String?
    /// Enters the chat's message multi-select mode with this message pre-selected - nil disables
    /// the "Select" context-menu action entirely, matching every other bubble type's convention.
    var onSelect: (() -> Void)?
    /// Double-tapping the preview card opens the owning message's quick-reaction menu (reactions +
    /// reply), exactly like double-tapping a normal message bubble. Nil disables it. Single tap
    /// still opens the link.
    var onDoubleTap: (() -> Void)?
    /// Whether the owning message is ours. Kept for callers; the cards are neutral.
    var isOutgoing: Bool = false
    /// Space held while the preview loads, so the card doesn't push the content below it down
    /// when it lands. Nil draws nothing until then.
    var loadingHeight: CGFloat? = nil

    @State private var preview: LinkPreviewData?
    @State private var hasFinishedLoading: Bool
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    init(url: URL, txId: String, fallbackText: String? = nil, onSelect: (() -> Void)? = nil, onDoubleTap: (() -> Void)? = nil, isOutgoing: Bool = false, loadingHeight: CGFloat? = nil) {
        self.loadingHeight = loadingHeight
        self.url = url
        self.txId = txId
        self.fallbackText = fallbackText
        self.onSelect = onSelect
        self.onDoubleTap = onDoubleTap
        self.isOutgoing = isOutgoing
        // If this exact URL was already resolved earlier (e.g. scrolled past once already, or
        // another row with the same link), seed state with the final result immediately instead
        // of starting in the "loading" state and waiting for `.task` to come back - avoids a
        // late height change on rows that are already off in older, scrolled-past history, which
        // is what was breaking pagination scroll-restoration.
        if let cached = LinkPreviewService.shared.cachedResultIfKnown(for: url) {
            _preview = State(initialValue: cached)
            _hasFinishedLoading = State(initialValue: true)
        } else {
            _preview = State(initialValue: nil)
            _hasFinishedLoading = State(initialValue: false)
        }
    }

    private static let videoHosts: Set<String> = ["youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com"]

    private var isVideoLink: Bool {
        guard let host = url.host?.lowercased() else { return false }
        return Self.videoHosts.contains(host)
    }

    var body: some View {
        Group {
            // Always some real, concrete content here (never a bare `EmptyView` from an `if`
            // with no `else`) - a `Group`/container whose content is *entirely* conditional and
            // starts out empty doesn't reliably run an attached `.task` in SwiftUI (confirmed:
            // this exact view stopped fetching once its only content was the conditional
            // `cardBody`, and started again the moment *any* unconditional view - even a plain
            // debug label - was added). `Color.clear` sized to zero keeps a stable, real view
            // identity for `.task` to attach to without taking up any visible space.
            if hasFinishedLoading, let preview {
                cardBody(preview)
            } else if hasFinishedLoading, let fallbackText {
                fallbackBubble(fallbackText)
            } else if let loadingHeight {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(maxWidth: 260)
                    .frame(height: loadingHeight)
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
        // The fetch starts on render: posts and rooms only make a card for an allowed link from a
        // poster or sender with a `.kachat` name; every other link stays plain text with no card
        // at all (owner's call, 2026-11-18).
        .task(id: url.absoluteString) {
            // Already seeded synchronously from the cache in `init` - skip re-running the fetch
            // (which would flip `hasFinishedLoading` false then true again, causing exactly the
            // late height-change flicker this seeding exists to avoid).
            guard !hasFinishedLoading else { return }
            let result = await LinkPreviewService.shared.preview(for: url)
            // With space held while loading (posts), the swap to the card or the plain link eases
            // instead of jumping from the placeholder's height.
            if loadingHeight != nil {
                withAnimation(.easeInOut(duration: 0.2)) {
                    preview = result
                    hasFinishedLoading = true
                }
            } else {
                preview = result
                hasFinishedLoading = true
            }
        }
    }

    @ViewBuilder
    private func cardBody(_ data: LinkPreviewData) -> some View {
        // A plain tappable view rather than a Button, so a double-tap can open the quick-reaction
        // menu while a single tap opens the link. The double-tap (`onDoubleTapIfSet`) is listed
        // first so it is claimed by that handler instead of also firing the single-tap open, and
        // only exists when there is one: otherwise every single tap would wait out the double-tap
        // window. Matches a normal message bubble's double-tap.
        cardContent(data)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onDoubleTapIfSet(onDoubleTap)
            .onTapGesture { openURL(url) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 260)
            .messageActions(title: "Link", preview: url.absoluteString) { menuActions() }
    }

    @ViewBuilder
    private func cardContent(_ data: LinkPreviewData) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                // A social network's link always shows the network's logo, not the post's image
                // (owner's call, 2026-11-18).
                if let social = SocialLinkLogo.logo(for: url) {
                    ZStack {
                        social.color
                        Image(social.asset)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                } else if let imageURLString = data.imageURLString, let imageURL = URL(string: imageURLString),
                          KaPostLinkPreviewPolicy.allowsImage(imageURL, forPage: url) {
                    // Only from the site or one of its image servers; any other host draws the
                    // card without the image rather than contacting it.
                    ZStack {
                        LinkPreviewImage(imageURL: imageURL, referer: url)
                            .frame(height: 140)
                            .frame(maxWidth: .infinity)
                            .clipped()

                        if isVideoLink {
                            Image(systemName: "play.circle.fill")
                                .font(.scaled(size: 40))
                                .foregroundStyle(.white, .black.opacity(0.45))
                                .shadow(color: .black.opacity(0.3), radius: 4)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let title = data.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let description = data.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let siteName = data.siteName, !siteName.isEmpty {
                        Text(siteName.uppercased())
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
            )
    }

    @ViewBuilder
    private func fallbackBubble(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onDoubleTapIfSet(onDoubleTap)
            .onTapGesture { openURL(url) }
            .messageActions(title: "Link", preview: url.absoluteString) { menuActions() }
    }

    /// No Copy Link for a Nextcloud-shaped share link: it is the address of someone's file.
    private func menuActions() -> [MessageAction] {
        var actions: [MessageAction] = []
        if LinkPreviewService.nextcloudShareEndpoints(for: url) == nil {
            actions.append(.copyLink { UIPasteboard.general.string = url.absoluteString })
        }
        if let explorerURL = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
            actions.append(.explorer(explorerURL))
        }
        if let onSelect { actions.append(.select(onSelect)) }
        return actions
    }
}

/// Loads a link-preview image through `LinkPreviewService.imageData` (browser User-Agent, and the
/// page as Referer only when the image is on the page's own host) instead of a bare `AsyncImage`,
/// so CDNs like cdninstagram/fbcdn that 403 header-less requests serve the image. Only drawn for an
/// image `KaPostLinkPreviewPolicy.allowsImage` takes. Shows a neutral placeholder until loaded or
/// on failure.
private struct LinkPreviewImage: View {
    let imageURL: URL
    /// The page the image belongs to: decides which image hosts are allowed, and is sent as the
    /// `Referer` only to the page's own host.
    let referer: URL
    @State private var uiImage: UIImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .task(id: imageURL) {
            guard !finished else { return }
            if let data = await LinkPreviewService.shared.imageData(imageURL, referer: referer),
               let image = await ImageThumbnail.decode(data, maxPixelSize: 1024) {
                uiImage = image
            }
            finished = true
        }
    }
}

private extension View {
    /// A double-tap only when there is something to do: an `onTapGesture(count: 2)` that does
    /// nothing still makes every single tap wait to see whether a second one follows.
    @ViewBuilder
    func onDoubleTapIfSet(_ action: (() -> Void)?) -> some View {
        if let action {
            onTapGesture(count: 2, perform: action)
        } else {
            self
        }
    }
}

/// The logo a social network's link preview shows in place of the post's image: the network's
/// mark in white on its brand colour. YouTube isn't here: its preview keeps the video's
/// thumbnail (owner's call, 2026-11-18). The marks are Simple Icons' (CC0), in the asset catalog as
/// template vectors (`Social*`).
enum SocialLinkLogo {
    struct Logo {
        let asset: String
        let color: Color
    }

    private static let byDomain: [(domain: String, logo: Logo)] = [
        ("x.com", Logo(asset: "SocialX", color: .black)),
        ("twitter.com", Logo(asset: "SocialX", color: .black)),
        ("instagram.com", Logo(asset: "SocialInstagram", color: Color(red: 0.894, green: 0.251, blue: 0.373))),
        ("facebook.com", Logo(asset: "SocialFacebook", color: Color(red: 0.031, green: 0.4, blue: 1))),
        ("linkedin.com", Logo(asset: "SocialLinkedIn", color: Color(red: 0.039, green: 0.4, blue: 0.761))),
        ("tiktok.com", Logo(asset: "SocialTikTok", color: .black)),
        ("threads.net", Logo(asset: "SocialThreads", color: .black)),
        ("threads.com", Logo(asset: "SocialThreads", color: .black)),
    ]

    /// The network's logo for a link to it (any subdomain: www., m., mobile.), or nil.
    static func logo(for url: URL) -> Logo? {
        guard let host = url.host?.lowercased() else { return nil }
        return byDomain.first(where: { host == $0.domain || host.hasSuffix("." + $0.domain) })?.logo
    }
}
