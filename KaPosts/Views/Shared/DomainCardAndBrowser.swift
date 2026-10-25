import SwiftUI
import WebKit
import UIKit

/// Teal card matching the app's KNS domain branding - used both as the row style in
/// KNSDomainsListView and as the header of KNSDomainDetailView.
struct KNSDomainCard: View {
    let domain: KNSDomain
    var isPrimary: Bool = false

    var body: some View {
        DomainNameCardView(title: domain.fullName, badge: isPrimary ? String(localized: "Primary") : nil)
    }
}


/// The teal name card, for any name service: the name, and an optional corner badge
/// ("Primary" on KNS, "Settling" on a `.kaspa` name still inside its settling window).
struct DomainNameCardView: View {
    let title: String
    var badge: String? = nil
    /// A small line in the bottom-right corner (Your Domains > .kachat: when it expires).
    var footnote: String? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 100)
                .overlay(
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 20)
                )

            if let badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let footnote {
                Text(verbatim: footnote)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.black.opacity(0.65))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }
}


/// Full-screen in-app browser: the X in the top-left is the ONLY way out (full-screen cover,
/// so there's no slide-down to dismiss).
///
/// While the browser is up, the app powers down like it was backgrounded: node discovery
/// pauses, the chat poll timer stops, the KaPosts notification poller stops, and (in
/// remote-push mode) the UTXO subscription is released so notifications arrive via push -
/// exactly the closed-app path. All of it resumes when the X is tapped.
struct InAppBrowserScreen: View {
    let url: URL
    /// Optional strip under the top bar (Claim Testnet Kaspa: "your address is copied").
    var notice: String? = nil
    let onClose: () -> Void

    @State private var isLoading = true

    private func powerDownForBrowsing() {
        Task { @MainActor in
            await NodePoolService.shared.pauseDiscovery()
            ChatService.shared.stopPollingTimerOnly()
            KaPostsNotificationService.shared.stop()
            if AppSettings.load().notificationMode == .remotePush {
                ChatService.shared.pauseUtxoSubscriptionForRemotePush()
            }
        }
    }

    private func powerUpAfterBrowsing() {
        Task { @MainActor in
            await NodePoolService.shared.resumeDiscovery()
            ChatService.shared.startPolling()
            KaPostsNotificationService.shared.start()
            if AppSettings.load().notificationMode == .remotePush {
                await ChatService.shared.resumeUtxoSubscriptionForRemotePush()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Haptics.impact(.light)
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.scaled(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(url.host ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if isLoading {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    Color.clear
                        .frame(width: 34, height: 34)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let notice {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundColor(.accentColor)
                    Text(verbatim: notice)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.15))
            }
            Divider()
            InAppWebView(url: url, isLoading: $isLoading)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { powerDownForBrowsing() }
        .onDisappear { powerUpAfterBrowsing() }
    }
}

private struct InAppWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: InAppWebView

        init(_ parent: InAppWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

