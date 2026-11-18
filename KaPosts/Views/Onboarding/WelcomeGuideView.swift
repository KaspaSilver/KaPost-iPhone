import SwiftUI

/// KaPost's first-run tour (owner's call, 2026-11-18), shaped like KaChat's `WelcomeGuideView`
/// with KaPost's own steps: welcome, language, currency, how KaPost uses Kaspa, funding the
/// chatting address, what's in the app, and the chatting address explained.
///
/// Shown once after an account is created or imported (`KaPostsTabView`), and replayable from
/// Profile > Help (the question mark at the Profile's top left). An onboarding run has no Skip
/// and comes back after a kill until Finish; a replay keeps Skip.
struct WelcomeGuideView: View {
    let onFinished: () -> Void
    /// Set by the presenter: true for the run after create or import, false for Help replays.
    var isOnboardingRun: Bool = false

    // MARK: - Onboarding-run pending marker (kill/relaunch re-present)

    /// `WalletManager.justCreatedNewWallet` is in memory only, so a guide cut short by a kill
    /// would never come back on its own. Set when the onboarding run is presented, cleared by
    /// Finish.
    static let onboardingRunPendingKey = "kaposts_onboarding_guide_pending"

    static var isOnboardingRunPending: Bool {
        UserDefaults.standard.bool(forKey: onboardingRunPendingKey)
    }

    static func markOnboardingRunPending() {
        UserDefaults.standard.set(true, forKey: onboardingRunPendingKey)
    }

    static func clearOnboardingRunPending() {
        UserDefaults.standard.removeObject(forKey: onboardingRunPendingKey)
    }

    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    private enum Step: Int, CaseIterable {
        case welcome
        case language
        case currency
        case fees
        case funding
        case features
        /// The guide's final step.
        case addressExplainer
    }

    @State private var step: Step = .welcome
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var chattingAddress: String {
        walletManager.currentWallet?.publicAddress ?? ""
    }

    private func go(to target: Step) {
        withAnimation(.easeInOut(duration: 0.2)) { step = target }
    }

    private func goBack() {
        guard let target = Step(rawValue: step.rawValue - 1) else { return }
        go(to: target)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Only a replay can skip: the run after create or import goes to Finish.
                    if !isOnboardingRun {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Skip") { onFinished() }
                        }
                    }
                }
        }
        .toast(message: toastMessage)
        .interactiveDismissDisabled(isOnboardingRun)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            scaffold(
                icon: "hand.wave.fill",
                title: "Welcome to KaPost",
                body: "Let's walk through the basics so you're ready to make your first post."
            ) { go(to: .language) }

        case .language:
            listStep(
                icon: "globe",
                title: "Choose Your Language",
                body: "Select the language you'd like to use in KaPost.",
                rows: AppLanguage.allCases.map { language in
                    AnyView(optionRow(language.displayName, selected: settingsViewModel.settings.language == language) {
                        settingsViewModel.settings.language = language
                        settingsViewModel.saveSettings()
                        settingsViewModel.applyLanguagePreference(language)
                    })
                }
            ) { go(to: .currency) }

        case .currency:
            listStep(
                icon: "dollarsign.circle",
                title: "Choose Your Currency",
                body: "Select the currency you'd like prices displayed in.",
                rows: AppCurrency.allCases.map { currency in
                    AnyView(optionRow(currency.displayName, selected: settingsViewModel.settings.currency == currency) {
                        settingsViewModel.settings.currency = currency
                        settingsViewModel.saveSettings()
                    })
                }
            ) { go(to: .fees) }

        case .fees:
            scaffold(
                icon: "network",
                title: "How KaPost Uses Kaspa",
                body: "Every post, reply, like and room message is a small transaction on the Kaspa network, signed by your account. The fee goes to the miners who secure the network."
            ) { go(to: .funding) }

        case .funding:
            fundingStep

        case .features:
            cardsStep(
                title: "What's in KaPost",
                subtitle: nil,
                cards: [
                    ("square.text.square", "Feed", nil,
                     "Following, Feed and Popular. Post, reply, like, repost and quote: everything lives on the Kaspa network."),
                    ("bubble.left.and.text.bubble.right", "Public Chats", nil,
                     "Rooms anyone can join, with text and voice notes. Pin your favourites to the top."),
                    ("gift", "Tips", nil,
                     "Tap Tip on a post to send its author Kaspa. Set a default tip in Settings > KaPost to tip with one tap."),
                ],
                buttonTitle: "Next"
            ) { go(to: .addressExplainer) }

        case .addressExplainer:
            cardsStep(
                title: "Your Chatting Address",
                subtitle: "Think of it as who you are on KaPost.",
                cards: [
                    ("person.crop.circle.badge.checkmark", "Who You Are", chattingAddress,
                     "Your posts and messages are signed by this address, so nobody else can post as you."),
                    ("paperplane.fill", "Paying for Posts", nil,
                     "Each post, like or room message takes a tiny amount of Kaspa from this address."),
                    ("eye.fill", "What Others Can See", nil,
                     "Anyone can see this address, its balance and everything you post. Use it only for KaPost and .kachat names."),
                ],
                buttonTitle: "Finish"
            ) { finishGuide() }
        }
    }

    // MARK: - Funding step

    private var fundingStep: some View {
        scaffold(
            icon: "qrcode",
            title: "Fund Your Chatting Address",
            body: "1 Kaspa is enough for about 500 posts, likes and room messages.",
            extra: {
                VStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = chattingAddress
                        Haptics.success()
                        showToast(chattingAddress.addressCopiedToastText)
                    } label: {
                        Text(verbatim: chattingAddress)
                            .font(.footnote.monospaced())
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 24)
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        ChattingAddressQRView(
                            address: chattingAddress,
                            balanceSompi: walletManager.currentWallet?.balanceSompi
                        )
                    } label: {
                        Label("Show QR Code", systemImage: "qrcode")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        ) { go(to: .features) }
    }

    private func finishGuide() {
        walletManager.justImportedWallet = false
        Self.clearOnboardingRunPending()
        onFinished()
    }

    // MARK: - Shared pieces

    /// Centred on a tall screen, scrolling on a short one (iPhone SE, large Dynamic Type), with
    /// the Previous / Next bar fixed below.
    private func centeringScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let built = content()
        return GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    built
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }

    private func heading(icon: String?, title: String, body: String?) -> some View {
        VStack(spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
            }
            Text(LocalizedStringKey(title))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let body {
                Text(LocalizedStringKey(body))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func scaffold(
        icon: String,
        title: String,
        body: String,
        buttonTitle: String = "Next",
        @ViewBuilder extra: () -> some View = { EmptyView() },
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            centeringScroll {
                VStack(spacing: 20) {
                    heading(icon: icon, title: title, body: body)
                    extra()
                }
                .padding(.vertical, 24)
            }
            bottomBar(title: buttonTitle, action: action)
        }
    }

    /// Language and currency: the option list is the part that scrolls.
    private func listStep(icon: String, title: String, body: String, rows: [AnyView],
                          action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 12)
            heading(icon: icon, title: title, body: body)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rows.indices, id: \.self) { rows[$0] }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }
            bottomBar(action: action)
        }
    }

    private func optionRow(_ label: String, selected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            onSelect()
        } label: {
            HStack {
                Text(verbatim: label)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func cardsStep(
        title: String,
        subtitle: String?,
        cards: [(icon: String, title: String, address: String?, caption: String)],
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            centeringScroll {
                VStack(spacing: 20) {
                    heading(icon: nil, title: title, body: subtitle)
                    VStack(spacing: 12) {
                        ForEach(cards.indices, id: \.self) { i in
                            card(cards[i])
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 24)
            }
            bottomBar(title: buttonTitle, action: action)
        }
    }

    private func card(_ card: (icon: String, title: String, address: String?, caption: String)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(card.title))
                    .font(.subheadline.weight(.semibold))
                if let address = card.address, !address.isEmpty {
                    Text(verbatim: address)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(LocalizedStringKey(card.caption))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Previous and Next (or Finish), always in the same place. Previous is dimmed on Welcome.
    private func bottomBar(title: String = "Next", action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button {
                goBack()
            } label: {
                Text("Previous")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(step == .welcome)
            .opacity(step == .welcome ? 0.35 : 1)

            Button(action: action) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) { toastMessage = nil }
            }
        }
    }
}
