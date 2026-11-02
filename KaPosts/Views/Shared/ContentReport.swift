import SwiftUI
import MessageUI

/// Reporting a post or room message (App Store guideline 1.2): the report goes to support by
/// email, where a person reads it. A phone with no mail account can't send one, so there the
/// report is copied and the fallback alert says where to send it.
struct ContentReport: Identifiable {
    static let supportEmail = "kaspasilver@gmail.com"

    let id = UUID()
    let body: String

    var mailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "KaPost report"),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    /// Opens the email, or copies the report and returns false, for the caller to show
    /// `contentReportFallback`.
    func send() -> Bool {
        guard MFMailComposeViewController.canSendMail(), let mailURL else {
            UIPasteboard.general.string = body
            return false
        }
        UIApplication.shared.open(mailURL)
        return true
    }
}

extension View {
    /// The alert for a report `ContentReport.send()` couldn't hand to Mail. Open Email is still
    /// there for another mail app.
    func contentReportFallback(_ report: Binding<ContentReport?>) -> some View {
        alert(
            "Report Copied",
            isPresented: Binding(
                get: { report.wrappedValue != nil },
                set: { if !$0 { report.wrappedValue = nil } }
            ),
            presenting: report.wrappedValue
        ) { unsent in
            Button("Open Email") {
                if let url = unsent.mailURL { UIApplication.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("This iPhone has no mail account set up. Paste the report into an email to \(ContentReport.supportEmail).")
        }
    }
}
