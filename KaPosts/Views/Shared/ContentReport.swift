import SwiftUI

/// Reporting a post or room message (App Store guideline 1.2): the report goes to support by
/// email, where a person reads it, in whatever mail app is the phone's default. If nothing can
/// open it, the report is copied and the fallback alert says where to send it.
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

    /// Opens the email. If no mail app takes it, copies the report and calls `onUnsent`, for the
    /// caller to show `contentReportFallback`.
    func send(onUnsent: @escaping () -> Void) {
        let body = body
        guard let mailURL else {
            UIPasteboard.general.string = body
            onUnsent()
            return
        }
        UIApplication.shared.open(mailURL) { opened in
            guard !opened else { return }
            UIPasteboard.general.string = body
            onUnsent()
        }
    }
}

extension View {
    /// The alert for a report `ContentReport.send` couldn't hand to a mail app.
    func contentReportFallback(_ report: Binding<ContentReport?>) -> some View {
        alert(
            "Report Copied",
            isPresented: Binding(
                get: { report.wrappedValue != nil },
                set: { if !$0 { report.wrappedValue = nil } }
            ),
            presenting: report.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text("No mail app could open it. Paste the report into an email to \(ContentReport.supportEmail).")
        }
    }
}
