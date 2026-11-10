import SwiftUI
import WebKit

/// What a reply carries under it in the thread (Plan KZ §6): **Sources (n)**, and for a grounded
/// Gemini reply Google's Search Suggestions, rendered from Google's own snippet.
struct ReplyAttachmentsView: View {
    let attachments: ReplyAttachments

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.sources.isEmpty {
                    WebSourcesButton(sources: attachments.sources)
                }
                if let suggestions = attachments.suggestions {
                    SearchSuggestionsView(suggestions: suggestions)
                }
            }
        }
    }
}

/// **Sources (n)**: tapping lists the pages by title and site; each opens in Safari.
struct WebSourcesButton: View {
    let sources: [WebSource]
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Sources (\(sources.count))", systemImage: "link")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint(Text("Lists the web pages this answer used"))
        .sheet(isPresented: $showing) {
            NavigationStack {
                List(sources, id: \.url) { source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(source.site)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("Sources")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showing = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Google's Search Suggestions under a grounded Gemini reply, as Google returns them: the
/// snippet is loaded unaltered into a small web view that does not scroll and is as tall as its
/// content. A tapped suggestion opens in Safari directly (`SearchSuggestionsLinkPolicy`): no
/// in-app browser, no interstitial, no tracking, and nothing is logged.
struct SearchSuggestionsView: View {
    let suggestions: SearchSuggestions
    @State private var height: CGFloat = 44

    var body: some View {
        SearchSuggestionsWebView(html: suggestions.renderedContent, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text("Google search suggestions"))
    }
}

private struct SearchSuggestionsWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing kept between snippets: no cookies, no cache, no site data.
        configuration.websiteDataStore = .nonPersistent()
        // The snippet is markup and style; nothing in it needs to run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        context.coordinator.initialLoadDone = false
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loaded: String?
        var initialLoadDone = false

        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let navigation: SearchSuggestionsLinkPolicy.Navigation
            if navigationAction.navigationType == .linkActivated {
                navigation = .linkTapped
            } else if !initialLoadDone, navigationAction.navigationType == .other,
                      navigationAction.request.url?.absoluteString == "about:blank" {
                navigation = .initialLoad
            } else {
                navigation = .other
            }
            switch SearchSuggestionsLinkPolicy.action(for: navigation, url: navigationAction.request.url) {
            case .allow:
                decisionHandler(.allow)
            case .openInSafari(let url):
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            initialLoadDone = true
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
                guard let self, let measured = value as? CGFloat ?? (value as? Double).map({ CGFloat($0) }),
                      measured > 0 else { return }
                self.height.wrappedValue = min(max(measured, 32), 240)
            }
        }
    }
}
