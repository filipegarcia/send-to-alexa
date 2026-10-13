import AlexaKit
import SwiftUI
import WebKit

/// Shows Amazon's own sign-in page in a private web view and reports back when Amazon redirects
/// to `/ap/maplanding` with an authorization code. Passwords and 2FA codes are typed into Amazon's page,
/// never into our code.
@MainActor
struct AmazonSignInView {
    let login: AmazonLoginRequest
    /// Called once with the redirect URL and the Amazon cookies collected during sign-in.
    let onRedirect: @MainActor (URL, [String: String]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(login: login, onRedirect: onRedirect)
    }

    @MainActor
    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        if #available(iOS 16.4, macOS 13.3, *) { webView.isInspectable = true }
        #endif

        let login = self.login
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in
            // Same pre-seeded cookies the Alexa app sends (see AmazonLoginRequest.signInCookies).
            for (name, value) in login.signInCookies {
                if let cookie = HTTPCookie(properties: [
                    .domain: ".\(login.region.domain)",
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .expires: Date().addingTimeInterval(3600),
                ]) {
                    await cookieStore.setCookie(cookie)
                }
            }
            webView.load(URLRequest(url: login.url))
        }
        return webView
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let login: AmazonLoginRequest
        let onRedirect: @MainActor (URL, [String: String]) -> Void
        private var finished = false

        init(login: AmazonLoginRequest, onRedirect: @escaping @MainActor (URL, [String: String]) -> Void) {
            self.login = login
            self.onRedirect = onRedirect
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, AmazonLoginRequest.isRedirect(url) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard !finished else { return }
            finished = true
            let domain = login.region.domain
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [onRedirect] cookies in
                var jar: [String: String] = [:]
                for cookie in cookies where cookie.domain.hasSuffix(domain) {
                    jar[cookie.name] = cookie.value
                }
                MainActor.assumeIsolated { onRedirect(url, jar) }
            }
        }
    }
}

#if os(iOS)
extension AmazonSignInView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif os(macOS)
extension AmazonSignInView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
