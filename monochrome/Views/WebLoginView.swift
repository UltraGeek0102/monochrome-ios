import SwiftUI
import WebKit

// MARK: - WebLoginView
// Opens monochrome.tf/login in an in-app browser so the user can authenticate
// through the real website. Session cookies are shared with AuthService's URLSession.

struct WebLoginView: View {
    @Binding var isPresented: Bool
    var onSuccess: () -> Void

    var body: some View {
        WebLoginRepresentable(isPresented: $isPresented, onSuccess: onSuccess)
            .ignoresSafeArea()
    }
}

// MARK: - UIViewControllerRepresentable wrapper

private struct WebLoginRepresentable: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onSuccess: () -> Void

    func makeUIViewController(context: Context) -> WebLoginViewController {
        WebLoginViewController(onSuccess: {
            onSuccess()
            isPresented = false
        }, onClose: {
            isPresented = false
        })
    }

    func updateUIViewController(_ uiViewController: WebLoginViewController, context: Context) {}
}

// MARK: - View Controller

class WebLoginViewController: UIViewController, WKNavigationDelegate {
    private var onSuccess: () -> Void
    private var onClose: () -> Void
    private var webView: WKWebView!
    private var hasDetectedLogin = false

    init(onSuccess: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSuccess = onSuccess
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Share cookies with the app's HTTPCookieStorage
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        view.addSubview(webView)

        // Close button
        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("Done", for: .normal)
        closeBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        closeBtn.setTitleColor(.white, for: .normal)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = UIColor(white: 0.15, alpha: 1)
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            closeBtn.configuration = config
        } else {
            var config = UIButton.Configuration.filled()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        config.baseBackgroundColor = UIColor(white: 0.15, alpha: 1)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        closeBtn.configuration = config
        }
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            webView.topAnchor.constraint(equalTo: closeBtn.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let url = URL(string: "https://monochrome.tf/login")!
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasDetectedLogin else { return }
        guard let urlStr = webView.url?.absoluteString else { return }

        // Detect successful login: navigated away from /login on monochrome.tf
        let isMonochrome = urlStr.contains("monochrome.tf")
        let isNotLogin = !urlStr.contains("/login") && !urlStr.contains("/signup")
        guard isMonochrome && isNotLogin else { return }

        hasDetectedLogin = true

        // Copy WKWebView cookies to HTTPCookieStorage for AuthService
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains("monochrome.tf") {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            Task {
                await AuthService.shared.finishWebLogin()
                await MainActor.run { self.onSuccess() }
            }
        }
    }

    @objc private func closeTapped() { onClose() }
}
