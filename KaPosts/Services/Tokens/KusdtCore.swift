import Foundation
import WebKit
import CryptoKit

/// Trestly's own kUSDT transaction builders (kusdt-open `bridge/packages/core/pkg-web`, the same
/// WebAssembly their wallet runs), run inside KaPost (owner's call, 2026-11-19): a KCC-20 input's
/// unlock script and compute budget come from running the token contract, which only their
/// runtime does exactly.
///
/// How it's kept safe:
/// - The three files ship in the app (`Resources/KusdtCore/`) and are checked against the SHA-256s
///   below before anything loads; the WebAssembly's is the one in kusdt-open's PROVENANCE.json.
/// - They're served only through a private scheme (`kusdt-core://`) to a hidden, non-persistent web
///   view that's never shown and navigates nowhere else. The page's Content-Security-Policy and a
///   content rule list both keep it off the network.
/// - KaPost hands it one request at a time (`run`) and reads back the signed transaction. A key goes
///   in only for the address being spent from, and only for that call.
@MainActor
final class KusdtCore: NSObject {
    static let shared = KusdtCore()

    /// kusdt-open b70707c: `kusdt_wasm_bg.wasm` (PROVENANCE.json `wasm`), its loader, and KaPost's page,
    /// by the name the page asks for: the bundle file (the loader ships as `.js.txt`, so Xcode copies
    /// it rather than treating it as source) and its SHA-256.
    private static let pinned: [String: (resource: String, ext: String, sha256: String)] = [
        "kusdt_wasm_bg.wasm": ("kusdt_wasm_bg", "wasm", "a7be48e962dab57902924ea71fbad31b073cd2ba2197ebcf0de83b0f2a54fd53"),
        "kusdt_wasm.js": ("kusdt_wasm.js", "txt", "be01841b7f2eb700acb38c7b36b9faef7d3deeefb7c86a233731afef0052dc78"),
        "kusdt-core.html": ("kusdt-core", "html", "ae26fe42e2554cf083014553ac881f9898fd7ec6f279e085b06b3ce908963784"),
    ]
    private static let scheme = "kusdt-core"

    enum CoreError: LocalizedError {
        case unavailable(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            case .refused(let why): return why
            }
        }
    }

    private var webView: WKWebView?
    private var files: [String: Data] = [:]
    private var ready = false
    /// A web view is being made and its page loaded; the callers wait in `waiting`.
    private var starting = false
    /// Every caller waiting for the load. Only `finish` resumes them, and it empties the list
    /// first, so none can be resumed twice.
    private var waiting: [CheckedContinuation<Void, Error>] = []
    /// Set only when the shipped files aren't the pinned ones. The bundle can't change while the
    /// app runs, so that one is kept; any other failure to start is tried again on the next run.
    private var pinFailure: String?
    /// Bumped whenever a web view is set up or dropped, so a late callback (a timeout, a failed
    /// navigation, a message) from an earlier one changes nothing.
    private var generation = 0
    /// How many times the web content process ended under us (`run` tries again once when it did).
    private var processEnds = 0
    /// The page has this long to load its WebAssembly before the start counts as failed.
    private static let loadTimeoutNanoseconds: UInt64 = 15_000_000_000
    /// The longest one builder call may take, so a review never spins forever (as KaPay).
    private static let callTimeoutNanoseconds: UInt64 = 30_000_000_000

    /// Runs one builder command on a JSON request; answers the result as JSON, or throws the
    /// builder's own error (`{"error": …}`). iOS may end the hidden web view's process (memory
    /// pressure, often while KaPost was in the background): the builder is then loaded again and
    /// the request tried once more. A build only signs, nothing goes out, so a second try is safe.
    func run(_ command: String, request: [String: Any]) async throws -> [String: Any] {
        let endsBefore = processEnds
        do {
            return try await runOnce(command, request: request)
        } catch {
            guard processEnds != endsBefore else { throw error }
            AppLog.log("[kUSDT] the builder's process ended during a request: loading it again")
            return try await runOnce(command, request: request)
        }
    }

    private func runOnce(_ command: String, request: [String: Any]) async throws -> [String: Any] {
        try await load()
        guard let webView else { throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder couldn't start.")) }
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: data, encoding: .utf8) else { throw CoreError.unavailable("bad request") }
        let answer: String?
        do {
            answer = try await withTimeout(Self.callTimeoutNanoseconds, view: webView) {
                try await webView.callAsyncJavaScript(
                    "return window.kusdtCore.ready ? window.kusdtCore.run(command, request) : null",
                    arguments: ["command": command, "request": json],
                    in: nil,
                    contentWorld: .page
                ) as? String
            }
        } catch let error as WKError where error.code == .webContentProcessTerminated || error.code == .webViewInvalidated {
            // the answer can arrive before the delegate hears the process ended: reset here too
            processEnded(webView)
            throw error
        }
        guard let text = answer,
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder gave no answer."))
        }
        if let error = parsed["error"] as? String { throw CoreError.refused(error) }
        return parsed
    }

    /// Runs `body`, or throws "no answer" after `nanoseconds`. Not a task group: a group waits for
    /// every child, and a JavaScript call that never answers would keep it waiting anyway. Whichever
    /// ends first resumes the caller, once (`Once`); a page that timed out is dropped, so the next
    /// run loads it again.
    private func withTimeout(_ nanoseconds: UInt64, view: WKWebView,
                             _ body: @escaping @MainActor () async throws -> String?) async throws -> String? {
        final class Once { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            Task { @MainActor in
                do {
                    let value = try await body()
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: value)
                } catch {
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(throwing: error)
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !once.done else { return }
                once.done = true
                AppLog.log("[kUSDT] the builder didn't answer in time: it loads again on the next use")
                if let self, view === self.webView, !self.starting { self.tearDown() }
                continuation.resume(throwing: CoreError.unavailable(AppLocalization.string("kUSDT's transaction builder gave no answer.")))
            }
        }
    }

    // MARK: Loading

    private func load() async throws {
        if ready, webView != nil { return }
        if let pinFailure { throw CoreError.unavailable(pinFailure) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiting.append(continuation)
            if !starting { start() }
        }
    }

    private func start() {
        tearDown()
        starting = true
        let current = generation
        // every file, checked before the web view exists
        if files.isEmpty {
            var checked: [String: Data] = [:]
            for (name, file) in Self.pinned {
                guard let url = Bundle.main.url(forResource: file.resource, withExtension: file.ext),
                      let data = try? Data(contentsOf: url),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    AppLog.log("[kUSDT] the builder file %@ is missing or not the pinned one: refused", name)
                    let why = AppLocalization.string("kUSDT's transaction builder isn't the pinned one, so it won't run.")
                    pinFailure = why
                    finish(current, error: why)
                    return
                }
                checked[name] = data
            }
            files = checked
        }
        // a page that never says it's ready (or fails) doesn't keep its callers waiting
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.loadTimeoutNanoseconds)
            guard let self, self.generation == current, self.starting else { return }
            AppLog.log("[kUSDT] the builder didn't start in time")
            self.finish(current, error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
        }
        // the rule list that blocks the network is compiled first, so the page never loads without it
        Task { @MainActor [weak self] in
            let rules = await Self.networkBlockingRules()
            guard let self, self.generation == current, self.starting else { return }
            self.openPage(current, rules: rules)
        }
    }

    private func openPage(_ current: Int, rules: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        configuration.userContentController.add(WeakMessageHandler(self), name: "kusdtCore")
        if let rules { configuration.userContentController.add(rules) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        guard let url = URL(string: "\(Self.scheme)://core/kusdt-core.html") else {
            finish(current, error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
            return
        }
        view.load(URLRequest(url: url))
    }

    /// Ends a start: ready, or failed (the web view goes, and the next `run` starts afresh). Only
    /// for the start still current; every waiting caller is resumed exactly once.
    private func finish(_ startGeneration: Int, error: String?) {
        guard startGeneration == generation, starting else { return }
        starting = false
        if let error {
            tearDown()
        } else {
            ready = true
        }
        let continuations = waiting
        waiting = []
        for c in continuations {
            if let error { c.resume(throwing: CoreError.unavailable(error)) } else { c.resume() }
        }
    }

    /// Drops the web view; anything still to come from it is ignored (`generation`).
    private func tearDown() {
        generation += 1
        ready = false
        if let webView {
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "kusdtCore")
        }
        webView = nil
    }

    /// The web content process ended (or the view was invalidated): the next `run` loads again.
    private func processEnded(_ view: WKWebView) {
        guard view === webView else { return }
        AppLog.log("[kUSDT] the builder's web content process ended")
        processEnds += 1
        if starting {
            finish(generation, error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
        } else {
            tearDown()
        }
    }

    fileprivate func received(_ body: Any, from view: WKWebView?) {
        guard let view, view === webView, let message = body as? [String: Any] else { return }
        if message["ready"] as? Bool == true {
            AppLog.log("[kUSDT] builder ready (%@)", (message["version"] as? String) ?? "?")
            finish(generation, error: nil)
        } else if let error = message["error"] as? String {
            AppLog.log("[kUSDT] builder failed to start: %@", error)
            finish(generation, error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
        }
    }

    // MARK: No network

    /// Compiled once per launch: a content rule list blocking every http, https, ws and wss load,
    /// on top of the page's own Content-Security-Policy. The page needs nothing but `kusdt-core://`.
    /// If it can't be compiled the page still loads, kept off the network by its policy alone.
    private static var blockingRules: WKContentRuleList?

    private static func networkBlockingRules() async -> WKContentRuleList? {
        if let blockingRules { return blockingRules }
        // WebKit's url-filter has no alternation, so one rule per scheme family
        let json = """
        [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}}]
        """
        let list: WKContentRuleList? = await withCheckedContinuation { continuation in
            guard let store = WKContentRuleListStore.default() else {
                continuation.resume(returning: nil)
                return
            }
            store.compileContentRuleList(forIdentifier: "kusdt-core-no-network", encodedContentRuleList: json) { list, _ in
                continuation.resume(returning: list)
            }
        }
        if list == nil { AppLog.log("[kUSDT] the no-network rule list didn't compile: the page's policy alone keeps it offline") }
        blockingRules = list
        return list
    }
}

// MARK: - Serving the pinned files

extension KusdtCore: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let name = urlSchemeTask.request.url?.lastPathComponent ?? ""
        guard let data = files[name] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = name.hasSuffix(".wasm") ? "application/wasm" : name.hasSuffix(".js") ? "text/javascript" : "text/html"
        let response = HTTPURLResponse(url: urlSchemeTask.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

extension KusdtCore: WKNavigationDelegate {
    /// The page goes nowhere but its own files.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == Self.scheme ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !ready else { return }
        finish(generation, error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !ready else { return }
        finish(generation, error: AppLocalization.string("kUSDT's transaction builder couldn't start."))
    }

    /// iOS ended the page's process: reset, so the next `run` loads it again (and a run in
    /// progress tries once more).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processEnded(webView)
    }
}

/// The content controller holds its handler strongly; this keeps the core from holding itself.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var core: KusdtCore?
    init(_ core: KusdtCore) { self.core = core }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let view = message.webView
        Task { @MainActor in self.core?.received(body, from: view) }
    }
}
