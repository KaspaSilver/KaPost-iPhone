import SwiftUI
import UIKit

/// A bot challenge from KaPlay, carried in a post (ONLINE_CHESS.md §7.2 in KaPlay-iPhone):
///
/// `kachatchess://bot/<level>?name=<bot name>&moves=<n>&by=<address>&game=<game id>`
///
/// `level` is 1 to 5 and is what makes it a challenge; a link without a valid one stays plain
/// text. Everything else is optional and attacker-controlled like any link in a post, so each
/// value is checked and a bad one dropped, and `url` is rebuilt from what passed: the card's
/// button is the one place KaPost opens this scheme (`KaChatLinkRouter.isSafeExternalLink` still
/// refuses it for every other link), and it only ever opens this exact shape.
struct KaPlayBotChallenge: Equatable {
    static let scheme = "kachatchess"
    static let levels = 1...5
    private static let nameLimit = 40

    let level: Int
    let botName: String?
    let moves: Int?
    let url: URL

    init?(url source: URL) {
        guard source.scheme?.lowercased() == Self.scheme, source.host?.lowercased() == "bot",
              let components = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        let parts = source.pathComponents.filter { $0 != "/" }
        // Digits only: Int() alone also takes "+3".
        guard parts.count == 1, parts[0].allSatisfy(\.isNumber), let level = Int(parts[0]),
              Self.levels.contains(level) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }

        let name = value("name").map(Self.cleanName) ?? ""
        let botName = name.isEmpty ? nil : name
        let moves: Int? = value("moves").flatMap { raw -> Int? in
            raw.allSatisfy(\.isNumber) ? Int(raw) : nil
        }.flatMap { (1...9_999).contains($0) ? $0 : nil }
        let by: String? = value("by").flatMap { KaspaAddress.isValid($0) ? $0 : nil }
        let game: String? = value("game").flatMap { raw -> String? in
            raw.count <= 128 && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                ? raw : nil
        }

        var rebuilt = URLComponents()
        rebuilt.scheme = Self.scheme
        rebuilt.host = "bot"
        rebuilt.path = "/\(level)"
        let items: [URLQueryItem] = [
            botName.map { URLQueryItem(name: "name", value: $0) },
            moves.map { URLQueryItem(name: "moves", value: String($0)) },
            by.map { URLQueryItem(name: "by", value: $0) },
            game.map { URLQueryItem(name: "game", value: $0) }
        ].compactMap { $0 }
        rebuilt.queryItems = items.isEmpty ? nil : items
        guard let url = rebuilt.url else { return nil }

        self.level = level
        self.botName = botName
        self.moves = moves
        self.url = url
    }

    /// No control or direction marks, which could make the card read as something else.
    private static func cleanName(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            let category = scalar.properties.generalCategory
            return category != .control && category != .format
        }
        return String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(nameLimit)
            .description
    }

    /// "Beat Coderofstuff (Level 3) in 14 moves", or "Challenge: beat Coderofstuff (Level 3)"
    /// without a move count.
    var title: String {
        let bot = botName.map { "\($0) (Level \(level))" } ?? "the Level \(level) bot"
        guard let moves else { return "Challenge: beat \(bot)" }
        return "Beat \(bot) in \(moves) \(moves == 1 ? "move" : "moves")"
    }

    // MARK: Detection inside post text

    struct Match: Equatable {
        let challenge: KaPlayBotChallenge
        /// The exact substring matched, which the post leaves out of its text.
        let matchedText: String
    }

    private static let regex = try? NSRegularExpression(
        pattern: #"kachatchess://bot/[^\s<>"']+"#,
        options: .caseInsensitive
    )
    /// Trailing prose punctuation is not part of the link ("... kachatchess://bot/3.").
    private static let trailingTrim = CharacterSet(charactersIn: ".,;:!?)]}'\"")

    private final class MatchBox: NSObject {
        let value: Match?
        init(_ value: Match?) { self.value = value }
    }

    /// Same caching convention (and reason) as `KaChatInternalLink.match`: this runs from post
    /// cell bodies, several times per cell per frame while scrolling.
    private static let matchCache: NSCache<NSString, MatchBox> = {
        let cache = NSCache<NSString, MatchBox>()
        cache.countLimit = 2_048
        return cache
    }()

    /// The first valid challenge in a post's text.
    static func match(in text: String) -> Match? {
        let key = text as NSString
        if let cached = matchCache.object(forKey: key) { return cached.value }
        let result = uncachedMatch(in: text)
        matchCache.setObject(MatchBox(result), forKey: key)
        return result
    }

    private static func uncachedMatch(in text: String) -> Match? {
        guard text.lowercased().contains("kachatchess://"), let regex else { return nil }
        let ns = text as NSString
        var found: Match?
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, stop in
            guard let result else { return }
            var candidate = ns.substring(with: result.range)
            while let last = candidate.unicodeScalars.last, trailingTrim.contains(last) {
                candidate.removeLast()
            }
            guard let url = URL(string: candidate), let challenge = KaPlayBotChallenge(url: url) else { return }
            found = Match(challenge: challenge, matchedText: candidate)
            stop.pointee = true
        }
        return found
    }
}

/// A challenge opens in KaPlay. Without KaPlay installed, the KaChat apps' install page opens.
enum KaPlayHandoff {
    /// The KaChat apps' install page, which links each app.
    static let appStoreURL = URL(string: "https://home.kachat.app/install/")!

    @MainActor
    static func open(_ challenge: KaPlayBotChallenge) {
        UIApplication.shared.open(challenge.url) { opened in
            if !opened { UIApplication.shared.open(appStoreURL) }
        }
    }
}

/// A bot challenge link in a KaPost, drawn as a card instead of the link's long text.
struct KaPostBotChallengeCard: View {
    let challenge: KaPlayBotChallenge

    var body: some View {
        Button {
            Haptics.impact(.light)
            KaPlayHandoff.open(challenge)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.scaled(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KaPlay Challenge")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .textCase(.uppercase)
                        Text(verbatim: challenge.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }

                HStack {
                    Spacer(minLength: 0)
                    Text("Challenge")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                        .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens KaPlay to play this bot."))
        .contextMenu {
            Button {
                UIPasteboard.general.string = challenge.url.absoluteString
                Haptics.success()
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
        }
    }
}
