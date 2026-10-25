import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(YbridOpus)
import YbridOpus
#endif

private let kaspaBubbleColor = OutgoingBubble.color

/// The preview card for a link that points back INSIDE KaChat (`KaChatInternalLink`): a shared
/// KaPosts post or a public chat-room invite. Deliberately NOT a `LinkPreviewCardView`: that card
/// scrapes the URL's server for Open Graph metadata, which for our own links would mean a
/// pointless network round trip (and, for a stranger's message, a tap-to-load placeholder) to
/// learn something the app already knows. Everything here is built locally, and a tap routes
/// in-app through `KaChatLinkRouter` instead of handing the URL to Safari.
///
/// Used by 1:1 bubbles (`MessageBubbleView`) and public chat rows (`PublicChatChannelView`).
struct KaChatInternalLinkCardView: View {
    let match: KaChatInternalLink.Match
    /// The owning message's transaction id, for the shared "View in Explorer" action - matches
    /// every other bubble type's identical action.
    let txId: String
    /// Enters the chat's message multi-select mode with this message pre-selected - nil disables
    /// the "Select" context-menu action, matching `LinkPreviewCardView`'s convention.
    var onSelect: (() -> Void)?
    /// Double-tap opens the owning message's quick-reaction bar, exactly like a normal bubble.
    var onDoubleTap: (() -> Void)?

    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    /// Observed, not read once: a post resolves off the chain a moment after the card first
    /// draws, and the card has to redraw as the real post when it lands.
    @ObservedObject private var kaPostCache = KaPostLinkPreviewCache.shared

    private var kaPostId: String? {
        guard case .kaPost(let txId) = match.link else { return nil }
        return txId
    }

    /// The post behind a shared link - author and text - once it has been recorded by a KaPosts
    /// surface or resolved from the chain. Nil until then, which is the neutral card below.
    private var kaPostEntry: KaPostLinkPreviewCache.Entry? {
        guard let kaPostId else { return nil }
        return kaPostCache.entry(for: kaPostId)
    }

    private var iconName: String {
        switch match.link {
        case .kaPost: return "square.and.pencil"          // AppTab.kaposts.icon
        case .publicChatRoom: return "dot.radiowaves.left.and.right" // AppTab.publicChats.icon
        case .profile: return "person.crop.circle"
        case .paymentRequest: return "arrow.up.circle"
        }
    }

    private var eyebrow: String {
        switch match.link {
        case .kaPost:
            // A reply or a quote is still a KaPosts post, but saying which one it is explains
            // why the text may read as half a conversation.
            switch kaPostEntry?.action {
            case "reply": return "KaPosts reply"
            case "quote": return "KaPosts quote"
            default: return "KaPosts"
            }
        case .publicChatRoom: return "Public Chat Room"
        case .profile: return "KaPosts Profile"
        case .paymentRequest: return "Payment Request"
        }
    }

    private var title: String {
        switch match.link {
        case .kaPost:
            return kaPostEntry?.authorName ?? "KaPosts post"
        case .publicChatRoom(let channel):
            return "#\(channel)"
        case .profile(let address):
            if let domain = KNSService.shared.identityInfo(for: address)?.primaryDomain {
                return domain
            }
            return ContactsManager.shared.displayName(for: address)
        case .paymentRequest(let request):
            return "\(request.amountText) \(KaspaUnit.symbol)"
        }
    }

    private var subtitle: String {
        switch match.link {
        case .kaPost:
            guard let entry = kaPostEntry else { return "Tap to open this post in KaPosts." }
            // A quote with no added comment is a repost: there is no text to show, so say what
            // it is rather than leaving the card looking half-loaded.
            return entry.snippet.isEmpty
                ? (entry.action == "quote" ? "Reposted a post." : "Tap to open this post in KaPosts.")
                : entry.snippet
        case .publicChatRoom(let channel):
            // Curated rooms and rooms already in the list just open; anything else is created
            // and added to the user's channel list on tap, so say so before they tap.
            let known = PublicChatService.curatedChannels.contains(channel)
                || PublicChatService.shared.channels.contains { $0.channelName == channel }
            return known
                ? "Tap to open this public chat room."
                : "Tap to join this public chat room."
        case .profile(let address):
            let isContact = ContactsManager.shared.contacts.contains { $0.address.lowercased() == address }
            return isContact ? "Tap to open your chat." : "Tap to see their KaPosts profile."
        case .paymentRequest(let request):
            let action = request.isOwn ? AppLocalization.string("Your payment request. Tap to view.") : AppLocalization.string("Tap to pay.")
            var lines: [String] = []
            if !request.memo.isEmpty { lines.append(request.memo) }
            // the maker, as the signature in the link proves - their name, not the payment address
            if let creator = request.creator, !request.isOwn {
                lines.append(String(format: AppLocalization.string("From %@"), ContactsManager.shared.displayName(for: creator)))
            }
            lines.append(action)
            return lines.joined(separator: "\n")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // A resolved post shows its AUTHOR, the same avatar the KaPosts feed draws for them
            // (KNS, falling back to their initial, and to the device contact photo where there is
            // one). The KaPosts glyph is for a post that hasn't resolved yet, and for room
            // invites, which have no author at all.
            if let entry = kaPostEntry, let address = entry.authorAddress, !address.isEmpty {
                KNSAvatarView(
                    avatarURLString: entry.authorAvatarURL,
                    fallbackText: entry.authorName ?? "",
                    size: 40,
                    contactAddress: address
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                    Image(systemName: iconName)
                        .font(.scaled(size: 18, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .textCase(.uppercase)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(kaPostEntry?.snippet.isEmpty == false ? 6 : 3)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        // Same glass card LinkPreviewCardView's placeholder uses, so an internal link sits in
        // the thread as a sibling of the external link cards rather than a foreign element.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Listed first so a double-tap is claimed here instead of also firing the single tap -
        // matches LinkPreviewCardView's identical pairing.
        .onTapGesture(count: 2) { onDoubleTap?() }
        .onTapGesture { KaChatLinkRouter.open(match.link) }
        .messageActions(title: "KaPosts Link", preview: match.url.absoluteString) { linkActions }
        .task(id: kaPostId) {
            guard let kaPostId else { return }
            await kaPostCache.load(postId: kaPostId)
        }
    }

    private var linkActions: [MessageAction] {
        var actions: [MessageAction] = [
            MessageAction(title: "Open in KaPosts", subtitle: "Opens it right here in the app.", systemImage: "arrow.up.forward.app") {
                KaChatLinkRouter.open(match.link)
            },
            .copyLink { UIPasteboard.general.string = match.url.absoluteString }
        ]
        if let explorerURL = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
            actions.append(.explorer(explorerURL))
        }
        if let onSelect { actions.append(.select(onSelect)) }
        return actions
    }
}

struct LinkifiedMessageTextView: UIViewRepresentable {
    let text: String
    let isOutgoing: Bool
    let isSingleEmojiOnly: Bool
    let onLinkLongPress: (URL) -> Void
    /// Double-tapping a link should still open the quick-reaction bar, matching the rest of the
    /// bubble - without this, the link's own tap recognizer (which `cancelsTouchesInView`)
    /// silently swallowed the touch before the bubble's ancestor double-tap gesture ever saw it.
    var onLinkDoubleTap: () -> Void = {}
    /// When false, tapping a link does nothing - only the long-press menu can open it. Used in
    /// public chat rooms, where links can come from anonymous public senders, so opening one
    /// should always require a deliberate long-press rather than a single accidental tap.
    var tapOpensLink: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        context.coordinator.textView = textView
        context.coordinator.configureGestureRecognizersIfNeeded()
        let attributed = context.coordinator.makeAttributedText(
            text: text,
            isOutgoing: isOutgoing,
            isSingleEmojiOnly: isSingleEmojiOnly
        )
        textView.attributedText = attributed
        context.coordinator.noteAssigned(attributed)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        let newValue = context.coordinator.makeAttributedText(
            text: text,
            isOutgoing: isOutgoing,
            isSingleEmojiOnly: isSingleEmojiOnly
        )
        // SwiftUI re-runs this on every parent render (typing indicator, status tick, scroll),
        // and assigning `attributedText` invalidates TextKit's layout even when the string is
        // identical, so skip the assignment unless the content or attributes actually changed.
        // `makeAttributedText` hands back the same instance while nothing changed, so the common
        // case is a pointer comparison; the O(n) `isEqual` only runs when the instance differs.
        if context.coordinator.isAssigned(newValue) { return }
        guard !(uiView.attributedText?.isEqual(to: newValue) ?? false) else {
            context.coordinator.noteAssigned(newValue)
            return
        }
        uiView.attributedText = newValue
        context.coordinator.noteAssigned(newValue)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Below this many characters the bubble may be narrower than its maximum, so the text is
    /// measured unconstrained first to find its natural width. Anything longer wraps past the
    /// maximum width no matter what, and that unconstrained pass - one enormous line through
    /// TextKit - is the single most expensive thing a long message did on every layout.
    private static let naturalWidthMeasureLimit = 80

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let screenWidth = UIScreen.main.bounds.width
        let maxBubbleWidth = screenWidth * 0.72
        let proposedWidth = proposal.width ?? maxBubbleWidth
        let targetMaxWidth = max(1, min(maxBubbleWidth, proposedWidth))

        // Measured once per (text, available width); SwiftUI asks several times per layout pass
        // and once more per re-render, and TextKit's answer does not change in between.
        if let cached = context.coordinator.cachedSize(forMaxWidth: targetMaxWidth) {
            return cached
        }

        let targetWidth: CGFloat
        if (uiView.attributedText?.length ?? 0) > Self.naturalWidthMeasureLimit {
            targetWidth = targetMaxWidth
        } else {
            let unconstrained = uiView.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            )
            targetWidth = max(1, min(targetMaxWidth, ceil(unconstrained.width)))
        }
        let fitting = uiView.sizeThatFits(
            CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let size = CGSize(width: targetWidth, height: ceil(fitting.height))
        context.coordinator.storeSize(size, forMaxWidth: targetMaxWidth)
        return size
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: LinkifiedMessageTextView
        weak var textView: UITextView?
        private var tapRecognizer: UITapGestureRecognizer?
        private var doubleTapRecognizer: UITapGestureRecognizer?
        private var longPressRecognizer: UILongPressGestureRecognizer?
        private var cachedText: String?
        private var cachedIsOutgoing = false
        private var cachedIsSingleEmojiOnly = false
        private var cachedAttributedText: NSAttributedString?
        /// The attributed string currently installed in the text view, by identity.
        private var assignedAttributedText: NSAttributedString?
        /// Measured sizes for the installed string, keyed by the available width (rounded to a
        /// point). Dropped whenever a different string is installed.
        private var sizesByMaxWidth: [Int: CGSize] = [:]

        init(parent: LinkifiedMessageTextView) {
            self.parent = parent
        }

        func isAssigned(_ attributed: NSAttributedString) -> Bool {
            assignedAttributedText === attributed
        }

        func noteAssigned(_ attributed: NSAttributedString) {
            if assignedAttributedText !== attributed {
                sizesByMaxWidth.removeAll()
            }
            assignedAttributedText = attributed
        }

        func cachedSize(forMaxWidth width: CGFloat) -> CGSize? {
            sizesByMaxWidth[Int(width.rounded())]
        }

        func storeSize(_ size: CGSize, forMaxWidth width: CGFloat) {
            sizesByMaxWidth[Int(width.rounded())] = size
        }

        func configureGestureRecognizersIfNeeded() {
            guard let textView else { return }
            if doubleTapRecognizer == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
                recognizer.delegate = self
                recognizer.numberOfTapsRequired = 2
                recognizer.cancelsTouchesInView = true
                textView.addGestureRecognizer(recognizer)
                doubleTapRecognizer = recognizer
            }
            if tapRecognizer == nil, let doubleTapRecognizer {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = true
                // A single tap only fires once the double-tap recognizer has had its chance and
                // failed - otherwise the first tap of a double-tap would open the link immediately
                // before the second tap ever lands.
                recognizer.require(toFail: doubleTapRecognizer)
                textView.addGestureRecognizer(recognizer)
                tapRecognizer = recognizer
            }
            guard longPressRecognizer == nil else { return }
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            recognizer.delegate = self
            recognizer.minimumPressDuration = 0.45
            recognizer.cancelsTouchesInView = true
            textView.addGestureRecognizer(recognizer)
            longPressRecognizer = recognizer
        }

        func makeAttributedText(text: String, isOutgoing: Bool, isSingleEmojiOnly: Bool) -> NSAttributedString {
            if let cachedText,
               cachedText == text,
               cachedIsOutgoing == isOutgoing,
               cachedIsSingleEmojiOnly == isSingleEmojiOnly,
               let cachedAttributedText {
                return cachedAttributedText
            }

            let baseColor = isSingleEmojiOnly ? UIColor.label : (isOutgoing ? UIColor.white : UIColor.label)
            let bodyFont = UIFont.preferredFont(forTextStyle: .body)
            let baseFont = isSingleEmojiOnly ? bodyFont.withSize(bodyFont.pointSize * 5.0) : bodyFont
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: baseColor
                ]
            )
            let fullRange = NSRange(location: 0, length: attributed.length)

            if let detector = SharedDetectors.link {
                detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                    guard let match, let url = match.url else { return }
                    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
                    attributed.addAttributes(
                        [
                            .link: url,
                            .foregroundColor: UIColor.systemBlue,
                            .underlineStyle: NSUnderlineStyle.single.rawValue
                        ],
                        range: match.range
                    )
                }
            }

            let result = NSAttributedString(attributedString: attributed)
            cachedText = text
            cachedIsOutgoing = isOutgoing
            cachedIsSingleEmojiOnly = isSingleEmojiOnly
            cachedAttributedText = result
            return result
        }

        @objc
        private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let textView else { return }
            guard parent.tapOpensLink else { return }
            let point = gesture.location(in: textView)
            guard let url = url(at: point, in: textView) else { return }
            // A link that points back into KaChat routes in-app. Handing our own universal link
            // to `UIApplication.shared.open` would bounce the user out to Safari instead - iOS
            // deliberately does not re-enter the app that opened it.
            // `openAnywhere` also keeps any non-web scheme from running on a tap.
            KaChatLinkRouter.openAnywhere(url)
        }

        @objc
        private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let textView else { return }
            let point = gesture.location(in: textView)
            guard url(at: point, in: textView) != nil else { return }
            parent.onLinkDoubleTap()
        }

        @objc
        private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let textView else { return }
            let point = gesture.location(in: textView)
            guard let url = url(at: point, in: textView) else { return }
            Task { @MainActor in LinkLongPress.lastFiredAt = Date() }
            parent.onLinkLongPress(url)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let textView else { return false }
            guard gestureRecognizer === tapRecognizer || gestureRecognizer === doubleTapRecognizer || gestureRecognizer === longPressRecognizer else {
                return true
            }
            let location = gestureRecognizer.location(in: textView)
            return url(at: location, in: textView) != nil
        }

        private func url(at point: CGPoint, in textView: UITextView) -> URL? {
            let textContainerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            guard textContainerPoint.x >= 0, textContainerPoint.y >= 0 else { return nil }

            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            let glyphIndex = layoutManager.glyphIndex(for: textContainerPoint, in: textContainer)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            guard glyphRect.contains(textContainerPoint) else { return nil }

            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard charIndex < textView.textStorage.length else { return nil }

            let attributes = textView.textStorage.attributes(at: charIndex, effectiveRange: nil)
            if let url = attributes[.link] as? URL {
                return url
            }
            if let urlString = attributes[.link] as? String {
                return URL(string: urlString)
            }
            return nil
        }

    }
}

/// Full text of a message too long to render inline (see `MessageBubbleView.inlineTextTruncationThreshold`)
/// - a plain scrollable, selectable text view, matching iMessage's "tap to see more" detail sheet.
/// Shared with `PublicChatChannelView`'s room bubble, not just private-chat messages.
struct FullMessageTextView: View {
    let text: String
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}

/// Bounds how many thumbnail decodes run at once. Without this, opening a chat with many
/// photos - especially jumping straight to the bottom of a long history, as happens when a
/// lock-screen notification tap cold-launches straight into a photo-heavy chat - fired one
/// `Task.detached(priority: .userInitiated)` base64-decode-and-downsample per bubble that
/// appeared, all at once. That can saturate every core while the main thread is also trying to
/// lay out/scroll the message list and, on a cold launch, while wallet unlock/node pool init are
/// already competing for the same CPU time - reading as a multi-second freeze rather than a
/// smooth scroll-in. Capping concurrency keeps CPU headroom free for that other work; each
/// decode is still cheap individually (ImageIO's downsampled thumbnail path), so a small cap
/// doesn't meaningfully slow down how soon photos appear.
private actor ImageDecodeLimiter {
    static let shared = ImageDecodeLimiter()

    private var availablePermits = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class AudioPlaybackHelper: NSObject, ObservableObject, AVAudioPlayerDelegate, @unchecked Sendable {
    @Published var isPlaying = false
    @Published var durationText: String = "--:--"
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var waveformSamples: [Float] = []

    private var player: AVAudioPlayer?
    private var tempPlaybackURL: URL?
    private var cachedDuration: TimeInterval?
    private var dataHash: Int?
    private var progressTimer: Timer?

    /// Every helper that has started playback, weakly. Each bubble owns its own helper (a per-row
    /// `@StateObject`), so the thread view has no handle on the one that is playing; it stops
    /// them all through here when the thread closes - see `stopAllPlayback()`. Main-thread only.
    private static let playingHelpers = NSHashTable<AudioPlaybackHelper>.weakObjects()

    /// Stop playback in every bubble. Called from the thread view's `onDisappear`, which is where
    /// "the user left the chat" is actually known - the row's own `onDisappear` also fires when a
    /// `LazyVStack` scrolls the bubble out of view, which used to cut the voice note off mid-play.
    static func stopAllPlayback() {
        for helper in playingHelpers.allObjects {
            helper.stop()
        }
        playingHelpers.removeAllObjects()
    }

    func preloadDuration(data: Data, mimeType: String) {
        let newHash = data.hashValue
        if dataHash == newHash, cachedDuration != nil {
            return // Already loaded for this data
        }
        dataHash = newHash

        isLoading = true
        Task { @MainActor [weak self] in
            do {
                let (duration, samples) = try await Self.loadAudioInfo(data: data, mimeType: mimeType)
                self?.cachedDuration = duration
                self?.durationText = self?.formattedDuration(duration) ?? "--:--"
                self?.waveformSamples = samples
                self?.isLoading = false
            } catch {
                self?.durationText = "--:--"
                self?.waveformSamples = Array(repeating: 0.3, count: 40)
                self?.isLoading = false
            }
        }
    }

    private static func loadAudioInfo(data: Data, mimeType: String) async throws -> (TimeInterval, [Float]) {
        if mimeType.lowercased().contains("webm") {
            let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
            let samples = extractWaveformSamples(from: decoded.url, sampleCount: 40)
            try? FileManager.default.removeItem(at: decoded.url)
            return (decoded.duration, samples)
        }
        if mimeType.lowercased().contains("ogg") || mimeType.lowercased().contains("opus") {
            let decoded = try OggOpusDecoder.decodeToPCMFile(data: data)
            let samples = extractWaveformSamples(from: decoded.url, sampleCount: 40)
            try? FileManager.default.removeItem(at: decoded.url)
            return (decoded.duration, samples)
        }
        // For other formats
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".audio")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let player = try AVAudioPlayer(contentsOf: tempURL)
        let samples = extractWaveformSamples(from: tempURL, sampleCount: 40)
        return (player.duration, samples)
    }

    private static func extractWaveformSamples(from url: URL, sampleCount: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        do {
            try file.read(into: buffer)
        } catch {
            return Array(repeating: 0.3, count: sampleCount)
        }

        guard let floatData = buffer.floatChannelData?[0] else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        let totalFrames = Int(buffer.frameLength)
        let framesPerSample = max(1, totalFrames / sampleCount)
        var samples: [Float] = []

        for i in 0..<sampleCount {
            let start = i * framesPerSample
            let end = min(start + framesPerSample, totalFrames)
            var maxAmp: Float = 0
            for j in start..<end {
                maxAmp = max(maxAmp, abs(floatData[j]))
            }
            // Normalize and clamp
            samples.append(min(1.0, max(0.1, maxAmp * 2)))
        }

        return samples
    }

    func togglePlayback(data: Data, mimeType: String) {
        if isPlaying {
            stop()
            return
        }

        do {
            try setPlaybackSession()
            player = try makePlayer(data: data, mimeType: mimeType)
            player?.delegate = self
            player?.prepareToPlay()
            if player?.play() != true {
                stop()
                return
            }
            isPlaying = true
            progress = 0
            Self.playingHelpers.add(self)
            startProgressTimer()
            if let duration = cachedDuration {
                durationText = formattedDuration(duration)
            } else {
                durationText = formattedDuration(player?.duration ?? 0)
            }
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        if let url = tempPlaybackURL {
            try? FileManager.default.removeItem(at: url)
            tempPlaybackURL = nil
        }
        isPlaying = false
        progress = 0
        if let duration = cachedDuration {
            durationText = formattedDuration(duration)
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            let duration = player.duration
            if duration > 0 {
                self.progress = player.currentTime / duration
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.isPlaying = false
            self.progress = 0
            if let url = self.tempPlaybackURL {
                try? FileManager.default.removeItem(at: url)
                self.tempPlaybackURL = nil
            }
            if let duration = self.cachedDuration {
                self.durationText = self.formattedDuration(duration)
            }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "--:--" }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func setPlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func makePlayer(data: Data, mimeType: String) throws -> AVAudioPlayer {
        if mimeType.lowercased().contains("webm") {
            let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
            tempPlaybackURL = decoded.url
            cachedDuration = decoded.duration
            durationText = formattedDuration(decoded.duration)
            return try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
        }
        if mimeType.lowercased().contains("ogg") || mimeType.lowercased().contains("opus") {
            let decoded = try OggOpusDecoder.decodeToPCMFile(data: data)
            tempPlaybackURL = decoded.url
            cachedDuration = decoded.duration
            durationText = formattedDuration(decoded.duration)
            return try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
        }
        return try AVAudioPlayer(data: data)
    }
}

#if canImport(YbridOpus) || OPUS_BRIDGE || OPUS_CATALYST
private enum WebMOpusDecodeError: LocalizedError {
    case invalidWebM(String)
    case missingOpusHead
    case invalidOpusHead
    case decoderInit(Int32)
    case decodeFailed(Int32)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidWebM(let details):
            return "Invalid WebM data. \(details)"
        case .missingOpusHead:
            return "Missing Opus header."
        case .invalidOpusHead:
            return "Invalid Opus header."
        case .decoderInit(let code):
            return "Opus decoder init failed (\(code))."
        case .decodeFailed(let code):
            return "Opus decode failed (\(code))."
        case .noAudio:
            return "No audio data."
        }
    }
}

struct WebMOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        let parsed = try parseWebM(data)
        let head = try parseOpusHead(parsed.opusHead)
        let packets = parsed.packets
        if packets.isEmpty {
            throw WebMOpusDecodeError.noAudio
        }

        let sampleRate = normalizedSampleRate(head.sampleRate)
        var opusError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(sampleRate), Int32(head.channels), &opusError) else {
            throw WebMOpusDecodeError.decoderInit(opusError)
        }
        defer { opus_decoder_destroy(decoder) }

        let maxFrameSize = Int(sampleRate / 1000.0 * 120.0)
        var samples = [Float]()
        samples.reserveCapacity(packets.count * maxFrameSize * head.channels)

        var tempBuffer = [Float](repeating: 0, count: maxFrameSize * head.channels)
        for packet in packets {
            let decodedFrames = packet.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OPUS_BAD_ARG
                }
                return opus_decode_float(
                    decoder,
                    base,
                    Int32(buffer.count),
                    &tempBuffer,
                    Int32(maxFrameSize),
                    0
                )
            }
            if decodedFrames < 0 {
                throw WebMOpusDecodeError.decodeFailed(decodedFrames)
            }
            let frameCount = Int(decodedFrames)
            let total = frameCount * head.channels
            samples.append(contentsOf: tempBuffer.prefix(total))
        }

        let skipFrames = Int(Double(head.preSkip) * sampleRate / 48_000.0)
        if skipFrames > 0 && samples.count >= skipFrames * head.channels {
            samples.removeFirst(skipFrames * head.channels)
        }

        let duration = TimeInterval(Double(samples.count / head.channels) / sampleRate)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-play-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(head.channels),
                                         interleaved: false) else {
            throw WebMOpusDecodeError.invalidWebM("Failed to build output format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count / head.channels)) else {
            throw WebMOpusDecodeError.invalidWebM("Failed to allocate output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count / head.channels)
        if let channels = buffer.floatChannelData {
            for channel in 0..<head.channels {
                var writeIndex = 0
                let channelPointer = channels[channel]
                for frameIndex in stride(from: channel, to: samples.count, by: head.channels) {
                    channelPointer[writeIndex] = samples[frameIndex]
                    writeIndex += 1
                }
            }
        }

        let audioFile = try AVAudioFile(forWriting: outputURL,
                                        settings: format.settings,
                                        commonFormat: format.commonFormat,
                                        interleaved: format.isInterleaved)
        try audioFile.write(from: buffer)

        return DecodedAudio(url: outputURL, duration: duration)
    }

    private struct OpusHead {
        let channels: Int
        let preSkip: Int
        let sampleRate: Double
    }

    private struct ParsedWebM {
        let opusHead: Data
        let packets: [Data]
    }

    private static func parseWebM(_ data: Data) throws -> ParsedWebM {
        var opusHead: Data?
        var packets: [Data] = []

        let containerIDs: Set<UInt64> = [
            0x18538067, // Segment
            0x1549A966, // Info
            0x1654AE6B, // Tracks
            0xAE,       // TrackEntry
            0x1F43B675, // Cluster
            0xA0        // BlockGroup - real WebM muxers (e.g. Android's AOSP MediaRecorder/
                        // MediaMuxer) commonly wrap an Opus frame in BlockGroup > Block rather
                        // than a bare SimpleBlock, unlike this app's own hand-rolled encoder.
        ]

        func parseElements(in range: Range<Int>) throws {
            var offset = range.lowerBound
            while offset < range.upperBound {
                let (id, idLen, _) = try readVInt(data, offset: offset, forSize: false)
                let sizeOffset = offset + idLen
                if sizeOffset >= range.upperBound { break }
                let (size, _, isUnknown, payloadStart) = try readElementSize(
                    data: data,
                    id: id,
                    sizeOffset: sizeOffset,
                    range: range
                )
                if payloadStart > range.upperBound { break }
                let payloadEnd: Int
                if isUnknown {
                    payloadEnd = range.upperBound
                } else {
                    let end = payloadStart + Int(size)
                    if end < payloadStart { break }
                    payloadEnd = min(end, range.upperBound)
                }

                if id == 0x63A2 {
                    opusHead = data.subdata(in: payloadStart..<payloadEnd)
                } else if id == 0xA3 || id == 0xA1 {
                    // SimpleBlock (0xA3) or Block (0xA1, inside a BlockGroup) - both share the
                    // same track-number/timecode/flags header layout for our purposes.
                    let block = data.subdata(in: payloadStart..<payloadEnd)
                    if let packet = try parseSimpleBlock(block) {
                        packets.append(packet)
                    }
                } else if containerIDs.contains(id) {
                    try parseElements(in: payloadStart..<payloadEnd)
                }

                if payloadEnd <= offset {
                    break
                }
                offset = payloadEnd
            }
        }

        try parseElements(in: 0..<data.count)

        guard let opusHead else {
            throw WebMOpusDecodeError.missingOpusHead
        }
        return ParsedWebM(opusHead: opusHead, packets: packets)
    }

    private static func parseSimpleBlock(_ data: Data) throws -> Data? {
        var offset = 0
        // Track number isn't validated against a fixed value (e.g. this app's own encoder
        // always uses track 1) - these files only ever contain a single audio track, and other
        // real-world muxers (Android's AOSP MediaRecorder among them) aren't guaranteed to number
        // it the same way, so any track number here is accepted.
        let (_, trackLen) = try readVIntValue(data, offset: offset)
        offset += trackLen
        guard offset + 3 <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Short SimpleBlock.")
        }
        let _ = Int16(bitPattern: UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
        offset += 2
        let flags = data[offset]
        offset += 1

        let lacing = (flags >> 1) & 0x03
        if lacing != 0 {
            // Skip rather than abort the whole file - one oddly-laced block shouldn't lose every
            // other valid packet already parsed.
            return nil
        }
        guard offset <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Short SimpleBlock payload.")
        }
        return data.subdata(in: offset..<data.count)
    }

    private static func readElementSize(
        data: Data,
        id: UInt64,
        sizeOffset: Int,
        range: Range<Int>
    ) throws -> (size: UInt64, sizeLen: Int, isUnknown: Bool, payloadStart: Int) {
        if id == 0x18538067, sizeOffset + 8 <= range.upperBound {
            let candidate = data[sizeOffset..<(sizeOffset + 8)]
            if candidate.allSatisfy({ $0 == 0xFF }) {
                return (0, 8, true, sizeOffset + 8)
            }
        }
        let (size, sizeLen, isUnknown) = try readVInt(data, offset: sizeOffset, forSize: true)
        return (size, sizeLen, isUnknown, sizeOffset + sizeLen)
    }

    private static func parseOpusHead(_ data: Data) throws -> OpusHead {
        guard data.count >= 19, data.starts(with: Array("OpusHead".utf8)) else {
            throw WebMOpusDecodeError.invalidOpusHead
        }
        let channels = Int(data[9])
        let preSkip = Int(readUInt16LE(data, offset: 10))
        let sampleRate = Double(readUInt32LE(data, offset: 12))
        return OpusHead(channels: max(1, channels), preSkip: preSkip, sampleRate: sampleRate)
    }

    private static func readVInt(_ data: Data, offset: Int, forSize: Bool) throws -> (value: UInt64, length: Int, isUnknown: Bool) {
        guard offset < data.count else {
            throw WebMOpusDecodeError.invalidWebM("Unexpected end of data.")
        }
        let first = data[offset]
        var mask: UInt8 = 0x80
        var length = 1
        while length <= 8 && (first & mask) == 0 {
            mask >>= 1
            length += 1
        }
        guard length <= 8 else {
            throw WebMOpusDecodeError.invalidWebM("Invalid VINT length.")
        }
        guard offset + length <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Truncated VINT.")
        }

        var value: UInt64
        if forSize {
            let leadingBit = mask
            value = UInt64(first & (leadingBit - 1))
        } else {
            value = UInt64(first)
        }
        if length > 1 {
            for index in 1..<length {
                value = (value << 8) | UInt64(data[offset + index])
            }
        }

        if forSize {
            let maxValue = (UInt64(1) << (7 * length)) - 1
            let isUnknown = value == maxValue
            return (value, length, isUnknown)
        }
        return (value, length, false)
    }

    private static func readVIntValue(_ data: Data, offset: Int) throws -> (value: UInt64, length: Int) {
        let (value, length, _) = try readVInt(data, offset: offset, forSize: true)
        return (value, length)
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func normalizedSampleRate(_ value: Double) -> Double {
        switch value {
        case 8_000, 12_000, 16_000, 24_000, 48_000:
            return value
        default:
            return 48_000
        }
    }
}

private enum OggOpusDecodeError: LocalizedError {
    case invalidOgg(String)
    case invalidOpusHead
    case decoderInit(Int32)
    case decodeFailed(Int32)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidOgg(let details):
            return "Invalid Ogg data. \(details)"
        case .invalidOpusHead:
            return "Invalid Opus header."
        case .decoderInit(let code):
            return "Opus decoder init failed (\(code))."
        case .decodeFailed(let code):
            return "Opus decode failed (\(code))."
        case .noAudio:
            return "No audio data."
        }
    }
}

private struct OggOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    /// Get duration from Ogg file by parsing granule position without full decode
    static func getDuration(data: Data) throws -> TimeInterval {
        // Find the last Ogg page and read its granule position
        var lastGranulePosition: UInt64 = 0
        var sampleRate: Double = 48_000
        var preSkip: Int = 0
        var offset = 0

        while offset + 27 <= data.count {
            guard data[offset..<(offset + 4)] == Data([0x4f, 0x67, 0x67, 0x53]) else {
                break
            }

            // Read granule position (bytes 6-13, little endian)
            let granule = readUInt64LE(data, offset: offset + 6)
            lastGranulePosition = granule

            let pageSegments = Int(data[offset + 26])
            let headerSize = 27 + pageSegments
            guard offset + headerSize <= data.count else { break }

            let segmentTable = data[(offset + 27)..<(offset + 27 + pageSegments)]
            let bodySize = segmentTable.reduce(0) { $0 + Int($1) }
            let bodyStart = offset + headerSize

            // Parse OpusHead from first page to get sample rate and pre-skip
            if offset == 0 && bodySize >= 19 {
                let headData = data[bodyStart..<(bodyStart + min(bodySize, 19))]
                if headData.starts(with: Array("OpusHead".utf8)) {
                    preSkip = Int(readUInt16LE(data, offset: bodyStart + 10))
                    sampleRate = Double(readUInt32LE(data, offset: bodyStart + 12))
                    if sampleRate == 0 { sampleRate = 48_000 }
                }
            }

            offset = bodyStart + bodySize
        }

        // Opus always uses 48kHz internally for granule position
        let totalSamples = Int64(lastGranulePosition) - Int64(preSkip)
        let duration = max(0, Double(totalSamples) / 48_000.0)
        return duration
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        let packets = try extractPackets(from: data)
        guard packets.count >= 2 else {
            throw OggOpusDecodeError.invalidOgg("Missing Opus header.")
        }
        guard packets[0].starts(with: Array("OpusHead".utf8)) else {
            throw OggOpusDecodeError.invalidOpusHead
        }
        let head = try parseOpusHead(packets[0])
        let audioPackets = packets.dropFirst(2)
        if audioPackets.isEmpty {
            throw OggOpusDecodeError.noAudio
        }

        let sampleRate = normalizedSampleRate(head.sampleRate)
        var opusError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(sampleRate), Int32(head.channels), &opusError) else {
            throw OggOpusDecodeError.decoderInit(opusError)
        }
        defer { opus_decoder_destroy(decoder) }

        let maxFrameSize = Int(sampleRate / 1000.0 * 120.0)
        var samples = [Float]()
        samples.reserveCapacity(audioPackets.count * maxFrameSize * head.channels)

        var tempBuffer = [Float](repeating: 0, count: maxFrameSize * head.channels)
        for packet in audioPackets {
            let decodedFrames = packet.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OPUS_BAD_ARG
                }
                return opus_decode_float(
                    decoder,
                    base,
                    Int32(buffer.count),
                    &tempBuffer,
                    Int32(maxFrameSize),
                    0
                )
            }
            if decodedFrames < 0 {
                throw OggOpusDecodeError.decodeFailed(decodedFrames)
            }
            let frameCount = Int(decodedFrames)
            let total = frameCount * head.channels
            samples.append(contentsOf: tempBuffer.prefix(total))
        }

        let skipFrames = Int(Double(head.preSkip) * sampleRate / 48_000.0)
        if skipFrames > 0 && samples.count >= skipFrames * head.channels {
            samples.removeFirst(skipFrames * head.channels)
        }

        let duration = TimeInterval(Double(samples.count / head.channels) / sampleRate)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-play-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(head.channels),
                                         interleaved: false) else {
            throw OggOpusDecodeError.invalidOgg("Failed to build output format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count / head.channels)) else {
            throw OggOpusDecodeError.invalidOgg("Failed to allocate output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count / head.channels)
        if let channels = buffer.floatChannelData {
            for channel in 0..<head.channels {
                var writeIndex = 0
                let channelPointer = channels[channel]
                for frameIndex in stride(from: channel, to: samples.count, by: head.channels) {
                    channelPointer[writeIndex] = samples[frameIndex]
                    writeIndex += 1
                }
            }
        }

        let audioFile = try AVAudioFile(forWriting: outputURL,
                                        settings: format.settings,
                                        commonFormat: format.commonFormat,
                                        interleaved: format.isInterleaved)
        try audioFile.write(from: buffer)

        return DecodedAudio(url: outputURL, duration: duration)
    }

    private struct OpusHead {
        let channels: Int
        let preSkip: Int
        let sampleRate: Double
    }

    private static func parseOpusHead(_ data: Data) throws -> OpusHead {
        guard data.count >= 19 else {
            throw OggOpusDecodeError.invalidOpusHead
        }
        let channels = Int(data[9])
        let preSkip = Int(readUInt16LE(data, offset: 10))
        let sampleRate = Double(readUInt32LE(data, offset: 12))
        return OpusHead(channels: max(1, channels), preSkip: preSkip, sampleRate: sampleRate)
    }

    private static func extractPackets(from data: Data) throws -> [Data] {
        var packets: [Data] = []
        var current = Data()
        var offset = 0

        while offset + 27 <= data.count {
            guard data[offset..<(offset + 4)] == Data([0x4f, 0x67, 0x67, 0x53]) else {
                throw OggOpusDecodeError.invalidOgg("Missing OggS at \(offset).")
            }
            let pageSegments = Int(data[offset + 26])
            let headerSize = 27 + pageSegments
            guard offset + headerSize <= data.count else {
                throw OggOpusDecodeError.invalidOgg("Short header.")
            }
            let segmentTable = data[(offset + 27)..<(offset + 27 + pageSegments)]
            let bodySize = segmentTable.reduce(0) { $0 + Int($1) }
            let bodyStart = offset + headerSize
            guard bodyStart + bodySize <= data.count else {
                throw OggOpusDecodeError.invalidOgg("Short body.")
            }
            var cursor = bodyStart
            for seg in segmentTable {
                let length = Int(seg)
                if length > 0 {
                    current.append(data[cursor..<(cursor + length)])
                }
                cursor += length
                if seg < 255 {
                    packets.append(current)
                    current = Data()
                }
            }
            offset = bodyStart + bodySize
        }
        return packets
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, offset: Int) -> UInt64 {
        UInt64(data[offset])
            | (UInt64(data[offset + 1]) << 8)
            | (UInt64(data[offset + 2]) << 16)
            | (UInt64(data[offset + 3]) << 24)
            | (UInt64(data[offset + 4]) << 32)
            | (UInt64(data[offset + 5]) << 40)
            | (UInt64(data[offset + 6]) << 48)
            | (UInt64(data[offset + 7]) << 56)
    }

    private static func normalizedSampleRate(_ value: Double) -> Double {
        switch value {
        case 8_000, 12_000, 16_000, 24_000, 48_000:
            return value
        default:
            return 48_000
        }
    }
}
#else
private enum WebMOpusDecodeError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio decoding is not supported on this platform."
    }
}

private enum OggOpusDecodeError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio decoding is not supported on this platform."
    }
}

struct WebMOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        throw WebMOpusDecodeError.unsupportedPlatform
    }
}

private struct OggOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        throw OggOpusDecodeError.unsupportedPlatform
    }

    static func getDuration(data: Data) throws -> TimeInterval {
        throw OggOpusDecodeError.unsupportedPlatform
    }
}
#endif

/// Pinch-zoomable full-screen image host. Internal (not private) because the Nextcloud media
/// viewer (`LinkPreviewCardView.swift`) reuses it for remote photos — same zoom behavior as
/// the local chat-photo preview.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4.0
        scrollView.minimumZoomScale = 1.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        @Binding var isZoomed: Bool

        init(isZoomed: Binding<Bool>) {
            _isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if isZoomed != zoomed {
                isZoomed = zoomed
            }
        }
    }
}

/// Small, non-interactive board render for the in-chat live game card. The full-screen
/// `ChessGameView` has its own interactive board renderer (tap-to-select, highlights) rather than
/// reusing this - different enough concerns (static thumbnail vs. tappable squares) that sharing
/// the layout code wasn't worth the added complexity.
private extension View {
    /// Long-press "View in Explorer" for any chess bubble (invite/live card/log entry) - mirrors
    /// `messageTextBubble`'s own long-press sheet, scoped down to just the one action since a
    /// chess envelope's own JSON isn't meaningful to offer as "Copy Message".
    func chessExplorerMenu(txId: String, settingsViewModel: SettingsViewModel, onRetry: (() -> Void)? = nil) -> some View {
        messageActions(title: "Chess") {
            var actions: [MessageAction] = []
            if let onRetry { actions.append(.retry(onRetry)) }
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                actions.append(.explorer(url))
            }
            return actions
        }
    }
}


/// A voice note that was sent through Nextcloud: the same play button, waveform and duration
/// as an on-chain voice note, fetched from the share's `/download` endpoint on first sight and
/// kept for the bubble's life. Before that the on-chain and Nextcloud paths looked nothing
/// alike - one played inline, the other was a file card that opened a separate screen.
struct NextcloudAudioBubble: View {
    let downloadURL: URL
    let shareURL: URL
    let fileName: String
    let isOutgoing: Bool
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil

    @StateObject private var helper = AudioPlaybackHelper()
    @State private var data: Data?
    @State private var failed = false

    private var mimeType: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "ogg", "opus", "oga": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        default: return "audio/mp4"
        }
    }

    var body: some View {
        Group {
            if let data {
                AudioBubble(
                    helper: helper,
                    data: data,
                    mimeType: mimeType,
                    isOutgoing: isOutgoing,
                    fileName: fileName,
                    txId: txId,
                    onCopy: onCopy,
                    onRetry: nil,
                    onReply: onReply,
                    onSelect: onSelect
                )
            } else {
                HStack(spacing: 10) {
                    if failed {
                        Image(systemName: "exclamationmark.circle")
                            .font(.scaled(size: 32))
                    } else {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failed ? "Voice message unavailable" : "Voice message")
                            .font(.subheadline.weight(.medium))
                        Text(failed ? "Tap to retry" : "Loading\u{2026}")
                            .font(.caption)
                            .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isOutgoing ? kaspaBubbleColor : Color(.systemGray5))
                .foregroundColor(isOutgoing ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture {
                    if failed {
                        failed = false
                        Task { await load() }
                    }
                }
            }
        }
        .task(id: downloadURL.absoluteString) {
            if data == nil { await load() }
        }
    }

    private func load() async {
        // Same fetcher the photo bubble uses: it sends the share link as Referer, which is
        // what Nextcloud's public download endpoint wants, and caps the size.
        if let bytes = await LinkPreviewService.shared.imageData(downloadURL, referer: shareURL, maxBytes: 30_000_000),
           !bytes.isEmpty {
            data = bytes
        } else {
            failed = true
        }
    }
}

private struct AudioBubble: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject var helper: AudioPlaybackHelper
    let data: Data
    let mimeType: String
    let isOutgoing: Bool
    let fileName: String
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
    var onSelect: (() -> Void)? = nil
    @State private var showShareSheet = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                helper.togglePlayback(data: data, mimeType: mimeType)
            } label: {
                if helper.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: helper.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.scaled(size: 32))
                }
            }
            .disabled(helper.isLoading)

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(
                    samples: helper.waveformSamples,
                    progress: helper.progress,
                    isOutgoing: isOutgoing
                )
                .frame(height: 24)

                Text(helper.durationText)
                    .font(.caption)
                    .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isOutgoing ? kaspaBubbleColor : Color(.systemGray5))
        .foregroundColor(isOutgoing ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .messageActions(title: "Voice Message") {
            var actions: [MessageAction] = [
                MessageAction(title: "Save Audio", subtitle: "Saves or shares the recording as a file.", systemImage: "square.and.arrow.down") {
                    showShareSheet = true
                }
            ]
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                actions.append(.explorer(url))
            }
            if let onReply { actions.append(.reply(onReply)) }
            if let onRetry { actions.append(.retry(onRetry)) }
            if let onSelect { actions.append(.select(onSelect)) }
            return actions
        }
        .tint(.accentColor)
        .sheet(isPresented: $showShareSheet) {
            AudioShareSheet(data: data, fileName: fileName, mimeType: mimeType)
        }
        .onAppear {
            helper.preloadDuration(data: data, mimeType: mimeType)
        }
        // No `onDisappear { helper.stop() }` here: inside the thread's `LazyVStack` that fires
        // whenever the bubble scrolls out of view, which killed the voice note mid-play the moment
        // the user scrolled. Leaving the thread stops playback via `LazyAudioBubble.stopAllPlayback()`.
    }
}

private struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let isOutgoing: Bool

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: barSpacing) {
                let displaySamples = samples.isEmpty ? Array(repeating: Float(0.3), count: 40) : samples
                ForEach(0..<displaySamples.count, id: \.self) { index in
                    let amplitude = CGFloat(displaySamples[index])
                    let barProgress = Double(index) / Double(displaySamples.count)
                    let isPlayed = barProgress < progress

                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(barColor(isPlayed: isPlayed))
                        .frame(width: barWidth, height: max(4, amplitude * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func barColor(isPlayed: Bool) -> Color {
        if isOutgoing {
            return isPlayed ? .white : .white.opacity(0.5)
        } else {
            return isPlayed ? kaspaBubbleColor : .gray.opacity(0.4)
        }
    }
}

private struct AudioShareSheet: UIViewControllerRepresentable {
    let data: Data
    let fileName: String
    let mimeType: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Create temp file for sharing
        let lowercasedMime = mimeType.lowercased()
        let fileExtension: String
        if lowercasedMime.contains("webm") {
            fileExtension = "webm"
        } else if lowercasedMime.contains("ogg") || lowercasedMime.contains("opus") {
            fileExtension = "ogg"
        } else {
            fileExtension = "m4a"
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName.hasSuffix(".\(fileExtension)") ? fileName : "\(fileName).\(fileExtension)")

        try? data.write(to: tempURL)

        let controller = UIActivityViewController(
            activityItems: [tempURL],
            applicationActivities: nil
        )
        // The copy is for the share sheet only; it used to stay in tmp until iOS purged it.
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: tempURL)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
