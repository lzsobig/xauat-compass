import SwiftUI
import WebKit

public struct MarkdownContentView: View {
    let content: String
    var onTimestampTapped: ((TimeInterval) -> Void)?
    @State private var height: CGFloat = 24

    public init(content: String, onTimestampTapped: ((TimeInterval) -> Void)? = nil) {
        self.content = content
        self.onTimestampTapped = onTimestampTapped
    }

    public var body: some View {
        AnswerWebView(content: content, onTimestampTapped: onTimestampTapped, height: $height)
            .frame(height: height)
    }
}

private struct AnswerWebView: UIViewRepresentable {
    let content: String
    var onTimestampTapped: ((TimeInterval) -> Void)?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "answerHeight")
        config.userContentController.add(context.coordinator, name: "answerSeek")
        context.coordinator.onTimestampTapped = onTimestampTapped
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        context.coordinator.content = content
        if let page = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "MathAssets") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTimestampTapped = onTimestampTapped
        guard coordinator.content != content else { return }
        coordinator.content = content
        coordinator.render(in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "answerHeight")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "answerSeek")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var content = ""
        var height: Binding<CGFloat>
        var onTimestampTapped: ((TimeInterval) -> Void)?
        private var ready = false

        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            render(in: webView)
        }

        func render(in view: WKWebView) {
            guard ready else { return }
            view.callAsyncJavaScript("window.showAnswer(source)", arguments: ["source": content],
                                     in: nil, in: .page, completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber, value.doubleValue.isFinite else { return }
            if message.name == "answerSeek", value.doubleValue >= 0 {
                onTimestampTapped?(value.doubleValue)
            } else if message.name == "answerHeight", value.doubleValue > 0 {
                height.wrappedValue = CGFloat(value.doubleValue)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(!ready && action.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}
