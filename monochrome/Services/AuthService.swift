import Foundation
import Combine
import AuthenticationServices
import UIKit
import WebKit

class AuthService: ObservableObject {
    static let shared = AuthService()

    // better-auth endpoints (matches web app's js/accounts/config.js + auth.js)
    private let authBase = "https://auth.monochrome.tf"
    private let appwriteEndpoint = "https://auth.monochrome.tf/v1"
    private let projectId = "auth-for-monochrome"

    @Published private(set) var currentUser: AuthUser?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let sessionKey = "monochrome_auth_session"
    private let tokenKey   = "monochrome_auth_token"

    // Session that persists cookies — same domain cookie from web login carries over
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: config)
    }()

    var isAuthenticated: Bool { currentUser != nil }

    init() { restoreSession() }

    // MARK: - Sign In (better-auth endpoint)

    func signIn(email: String, password: String) async throws {
        await MainActor.run { isLoading = true; errorMessage = nil }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        let url = URL(string: "\(authBase)/api/auth/sign-in/email")!
        let body: [String: Any] = ["email": email, "password": password]

        let (data, response) = try await authenticatedRequest(url: url, method: "POST", body: body)

        guard let http = response as? HTTPURLResponse else { throw AuthError.networkError }

        if http.statusCode == 403 {
            throw AuthError.serverError("Login is only available through the Monochrome website. Use 'Sign in with Browser' below.")
        }
        if http.statusCode >= 400 {
            let msg = (try? JSONDecoder().decode(BetterAuthError.self, from: data))?.message ?? "Login failed"
            throw AuthError.serverError(msg)
        }

        // better-auth returns { token, user } or sets a session cookie
        if let result = try? JSONDecoder().decode(BetterAuthSignInResponse.self, from: data) {
            if let token = result.token {
                defaults.set(token, forKey: tokenKey)
            }
            if let user = result.user {
                let authUser = AuthUser(uid: user.id, email: user.email, name: user.name)
                await MainActor.run { self.currentUser = authUser }
                saveSession(authUser)
                return
            }
        }

        // Fallback: fetch user with session cookie
        try await fetchCurrentUser()
    }

    // MARK: - Sign Up (better-auth endpoint)

    func signUp(email: String, password: String) async throws {
        await MainActor.run { isLoading = true; errorMessage = nil }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        let url = URL(string: "\(authBase)/api/auth/sign-up/email")!
        let name = email.components(separatedBy: "@").first ?? "User"
        let body: [String: Any] = ["email": email, "password": password, "name": name]

        let (data, response) = try await authenticatedRequest(url: url, method: "POST", body: body)
        guard let http = response as? HTTPURLResponse else { throw AuthError.networkError }

        if http.statusCode == 403 {
            throw AuthError.serverError("Sign up is only available through the Monochrome website. Use 'Sign in with Browser' below.")
        }
        if http.statusCode >= 400 {
            let msg = (try? JSONDecoder().decode(BetterAuthError.self, from: data))?.message ?? "Sign up failed"
            throw AuthError.serverError(msg)
        }

        try await signIn(email: email, password: password)
    }

    // MARK: - Google OAuth (ASWebAuthenticationSession - works natively)

    func signInWithGoogle() async throws {
        await MainActor.run { isLoading = true; errorMessage = nil }
        defer { Task { await MainActor.run { self.isLoading = false } } }

        let callbackScheme = "appwrite-callback-\(projectId)"
        let successURL = "\(callbackScheme)://auth/callback"
        let failureURL = "\(callbackScheme)://auth/failure"

        guard let encodedSuccess = successURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedFailure = failureURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let oauthURL = URL(string: "\(appwriteEndpoint)/account/tokens/oauth2/google?project=\(projectId)&success=\(encodedSuccess)&failure=\(encodedFailure)") else {
            throw AuthError.serverError("Invalid OAuth URL")
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: oauthURL, callbackURLScheme: callbackScheme) { url, error in
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: AuthError.cancelled)
                    } else {
                        continuation.resume(throwing: AuthError.serverError(error.localizedDescription))
                    }
                    return
                }
                guard let url = url else {
                    continuation.resume(throwing: AuthError.serverError("No callback URL received"))
                    return
                }
                continuation.resume(returning: url)
            }
            session.prefersEphemeralWebBrowserSession = false

            DispatchQueue.main.async {
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let window = scene.windows.first else {
                    continuation.resume(throwing: AuthError.serverError("No window available"))
                    return
                }
                let provider = OAuthPresentationContextProvider(anchor: window)
                session.presentationContextProvider = provider
                objc_setAssociatedObject(window.rootViewController!, "oauthSession", session, .OBJC_ASSOCIATION_RETAIN)
                objc_setAssociatedObject(window.rootViewController!, "oauthProvider", provider, .OBJC_ASSOCIATION_RETAIN)
                session.start()
            }
        }

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let userId = components.queryItems?.first(where: { $0.name == "userId" })?.value,
              let secret = components.queryItems?.first(where: { $0.name == "secret" })?.value else {
            throw AuthError.serverError("Missing OAuth credentials in callback")
        }

        let sessionURL = URL(string: "\(appwriteEndpoint)/account/sessions/token")!
        let sessionBody: [String: Any] = ["userId": userId, "secret": secret]
        let (_, _) = try await authenticatedRequest(url: sessionURL, method: "POST", body: sessionBody)
        try await fetchCurrentUser()
    }

    // MARK: - Session cookie login (after web login via WKWebView)
    // Called by WebLoginView after the user logs in through monochrome.tf

    func finishWebLogin() async {
        do {
            try await fetchCurrentUser()
        } catch {
            // Session cookie not set yet
        }
    }

    // MARK: - Fetch Current User

    @discardableResult
    func fetchCurrentUser() async throws -> AuthUser {
        // Try better-auth session endpoint first
        if let user = try? await fetchBetterAuthUser() {
            await MainActor.run { self.currentUser = user }
            saveSession(user)
            return user
        }
        // Fallback: try Appwrite
        let url = URL(string: "\(appwriteEndpoint)/account")!
        let (data, response) = try await authenticatedRequest(url: url, method: "GET")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.networkError
        }
        let account = try JSONDecoder().decode(AppwriteAccount.self, from: data)
        let user = AuthUser(uid: account.id, email: account.email, name: account.name.isEmpty ? nil : account.name)
        await MainActor.run { self.currentUser = user }
        saveSession(user)
        return user
    }

    private func fetchBetterAuthUser() async throws -> AuthUser? {
        let url = URL(string: "\(authBase)/api/auth/get-session")!
        let (data, response) = try await authenticatedRequest(url: url, method: "GET")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let session = try? JSONDecoder().decode(BetterAuthSession.self, from: data),
              let user = session.user else { return nil }
        return AuthUser(uid: user.id, email: user.email, name: user.name)
    }

    // MARK: - Sign Out

    func signOut() async {
        // Clear better-auth session
        let _ = try? await authenticatedRequest(url: URL(string: "\(authBase)/api/auth/sign-out")!, method: "POST")
        // Clear Appwrite session
        let _ = try? await authenticatedRequest(url: URL(string: "\(appwriteEndpoint)/account/sessions/current")!, method: "DELETE")

        // Clear cookies for both domains
        for domain in ["auth.monochrome.tf", "monochrome.tf"] {
            if let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://\(domain)")!) {
                cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
            }
        }

        defaults.removeObject(forKey: sessionKey)
        defaults.removeObject(forKey: tokenKey)
        await MainActor.run { currentUser = nil }
    }

    // MARK: - Session Persistence

    private func saveSession(_ user: AuthUser) {
        if let data = try? JSONEncoder().encode(user) {
            defaults.set(data, forKey: sessionKey)
        }
    }

    private func restoreSession() {
        guard let data = defaults.data(forKey: sessionKey),
              let user = try? JSONDecoder().decode(AuthUser.self, from: data) else { return }
        currentUser = user
        Task {
            do { try await fetchCurrentUser() } catch { await signOut() }
        }
    }

    // MARK: - HTTP Helper

    private func authenticatedRequest(url: URL, method: String, body: [String: Any]? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://monochrome.tf", forHTTPHeaderField: "Origin")
        request.setValue("https://monochrome.tf/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        request.setValue(projectId, forHTTPHeaderField: "X-Appwrite-Project")

        if let token = defaults.string(forKey: tokenKey) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await urlSession.data(for: request)
    }
}

// MARK: - WebLoginView
// Opens monochrome.tf inside an in-app WKWebView so the user can log in
// through the real website. Session cookies are shared with AuthService's URLSession.

struct WebLoginView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onSuccess: () -> Void

    func makeUIViewController(context: Context) -> WebLoginViewController {
        WebLoginViewController(isPresented: $isPresented, onSuccess: onSuccess)
    }
    func updateUIViewController(_ vc: WebLoginViewController, context: Context) {}
}

class WebLoginViewController: UIViewController, WKNavigationDelegate {
    private var isPresented: Binding<Bool>
    private var onSuccess: () -> Void
    private var webView: WKWebView!

    init(isPresented: Binding<Bool>, onSuccess: @escaping () -> Void) {
        self.isPresented = isPresented
        self.onSuccess = onSuccess
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Share cookies with the app's HTTPCookieStorage
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)

        // Close button
        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("Done", for: .normal)
        closeBtn.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        closeBtn.setTitleColor(.white, for: .normal)
        closeBtn.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        let url = URL(string: "https://monochrome.tf/login")!
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Detect successful login by checking if we're redirected away from /login
        guard let url = webView.url?.absoluteString else { return }
        if !url.contains("/login") && url.contains("monochrome.tf") {
            // Copy WKWebView cookies to HTTPCookieStorage for AuthService
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                for cookie in cookies where cookie.domain.contains("monochrome.tf") {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                Task {
                    await AuthService.shared.finishWebLogin()
                    await MainActor.run {
                        self.onSuccess()
                        self.isPresented.wrappedValue = false
                    }
                }
            }
        }
    }

    @objc private func close() {
        isPresented.wrappedValue = false
    }
}

// MARK: - OAuth Helper

private class OAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

// MARK: - Models

struct AuthUser: Codable {
    let uid: String
    let email: String
    let name: String?
}

enum AuthError: LocalizedError {
    case serverError(String)
    case networkError
    case cancelled

    var errorDescription: String? {
        switch self {
        case .serverError(let message): return message
        case .networkError: return "Network error. Please check your connection."
        case .cancelled: return nil
        }
    }
}

private struct BetterAuthSignInResponse: Decodable {
    let token: String?
    let user: BetterAuthUser?
}

private struct BetterAuthSession: Decodable {
    let user: BetterAuthUser?
}

private struct BetterAuthUser: Decodable {
    let id: String
    let email: String
    let name: String?
}

private struct BetterAuthError: Decodable {
    let message: String
}

private struct AppwriteAccount: Decodable {
    let id: String
    let email: String
    let name: String
    enum CodingKeys: String, CodingKey {
        case id = "$id"
        case email, name
    }
}

struct AppwriteEmpty: Decodable { init() {} }
