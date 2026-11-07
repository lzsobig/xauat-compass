import SwiftUI
import WebKit

struct ContentView: View {
    @State private var loadFailed = false
    @State private var reload = UUID()

    var body: some View {
        ZStack {
            ClassroomWebView(loadFailed: $loadFailed)
                .id(reload)
            if loadFailed {
                VStack(spacing: 16) {
                    Text("课堂页面暂时无法加载")
                    Button("重试") {
                        loadFailed = false
                        reload = UUID()
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }
}

struct ClassroomWebView: UIViewRepresentable {
    private static let classroomURL = URL(string: "https://compass.lzso.top/classroom")!
    @Binding var loadFailed: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: Self.classroomURL, timeoutInterval: 30))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(loadFailed: $loadFailed)
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        @Binding private var loadFailed: Bool

        init(loadFailed: Binding<Bool>) {
            _loadFailed = loadFailed
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let isClassroom = origin.protocol == "https"
                && origin.host == ClassroomWebView.classroomURL.host
                && frame.isMainFrame
            decisionHandler(isClassroom && type == .microphone ? .prompt : .deny)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                loadFailed = true
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadFailed = true
        }
    }
}
