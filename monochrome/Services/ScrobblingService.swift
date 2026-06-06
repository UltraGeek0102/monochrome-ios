import Foundation
import Combine
import CryptoKit

// MARK: - ScrobblingService
// Handles Last.fm and ListenBrainz scrobbling, mirroring the web app's lastfm.js / listenbrainz.js

class ScrobblingService: ObservableObject {
    static let shared = ScrobblingService()

    // MARK: - Settings keys
    private let lastfmSessionKey  = "monochrome_lastfm_session_key"
    private let lastfmUsernameKey = "monochrome_lastfm_username"
    private let lastfmEnabledKey  = "monochrome_lastfm_enabled"
    private let lbTokenKey        = "monochrome_listenbrainz_token"
    private let lbEnabledKey      = "monochrome_listenbrainz_enabled"

    // MARK: - Last.fm constants (same as web app)
    private let lfmApiKey    = "85214f5abbc730e78770f27784b9bdf7"
    private let lfmApiSecret = "2c2c37fd86739191860db810dd063192"
    private let lfmApiUrl    = "https://ws.audioscrobbler.com/2.0/"

    // MARK: - Published state
    @Published var lastfmUsername: String?
    @Published var lastfmEnabled: Bool = false
    @Published var listenBrainzEnabled: Bool = false
    @Published var isAuthenticating = false

    private var lastfmSession: String?
    private var listenBrainzToken: String?

    // Scrobble tracking
    private var currentTrack: Track?
    private var trackStartTime: Date?
    private var hasScrobbled = false
    private var scrobbleTask: Task<Void, Never>?

    private init() {
        loadCredentials()
    }

    // MARK: - Credential management

    private func loadCredentials() {
        lastfmSession  = UserDefaults.standard.string(forKey: lastfmSessionKey)
        lastfmUsername = UserDefaults.standard.string(forKey: lastfmUsernameKey)
        lastfmEnabled  = UserDefaults.standard.bool(forKey: lastfmEnabledKey)
        listenBrainzToken   = UserDefaults.standard.string(forKey: lbTokenKey)
        listenBrainzEnabled = UserDefaults.standard.bool(forKey: lbEnabledKey)
    }

    private func saveLastfmSession(key: String, username: String) {
        lastfmSession  = key
        lastfmUsername = username
        UserDefaults.standard.set(key,      forKey: lastfmSessionKey)
        UserDefaults.standard.set(username, forKey: lastfmUsernameKey)
    }

    func setLastfmEnabled(_ enabled: Bool) {
        lastfmEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: lastfmEnabledKey)
    }

    func setListenBrainzToken(_ token: String) {
        listenBrainzToken = token.isEmpty ? nil : token
        UserDefaults.standard.set(token, forKey: lbTokenKey)
    }

    func setListenBrainzEnabled(_ enabled: Bool) {
        listenBrainzEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: lbEnabledKey)
    }

    func signOutLastfm() {
        lastfmSession  = nil
        lastfmUsername = nil
        lastfmEnabled  = false
        UserDefaults.standard.removeObject(forKey: lastfmSessionKey)
        UserDefaults.standard.removeObject(forKey: lastfmUsernameKey)
        UserDefaults.standard.set(false, forKey: lastfmEnabledKey)
    }

    var isLastfmAuthenticated: Bool { lastfmSession != nil && lastfmEnabled }
    var isListenBrainzAuthenticated: Bool { listenBrainzToken != nil && listenBrainzEnabled }

    // MARK: - Track lifecycle (called by AudioPlayerService)

    /// Call when a new track starts playing
    func trackDidStart(_ track: Track) {
        scrobbleTask?.cancel()
        currentTrack  = track
        trackStartTime = Date()
        hasScrobbled  = false

        Task {
            await updateNowPlaying(track)
            scheduleScrobble(track)
        }
    }

    /// Call when playback stops / app backgrounds
    func trackDidStop() {
        scrobbleTask?.cancel()
    }

    private func scheduleScrobble(_ track: Track) {
        // Scrobble at 50% of duration or 4 minutes, whichever comes first (Last.fm rules)
        let duration = TimeInterval(track.duration)
        let delay = min(duration * 0.5, 240)
        guard delay > 0 else { return }

        scrobbleTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !hasScrobbled else { return }
            await scrobble(track)
        }
    }

    // MARK: - Last.fm

    private func updateNowPlaying(_ track: Track) async {
        guard isLastfmAuthenticated, let session = lastfmSession else { return }

        var params: [String: String] = [
            "method":    "track.updateNowPlaying",
            "api_key":   lfmApiKey,
            "sk":        session,
            "artist":    track.artist?.name ?? "Unknown Artist",
            "track":     track.title,
        ]
        if let album = track.album?.title { params["album"] = album }
        if track.duration > 0 { params["duration"] = "\(track.duration)" }

        params["api_sig"] = generateSignature(params: params)
        params["format"]  = "json"

        _ = try? await lfmPost(params: params)
    }

    private func scrobble(_ track: Track) async {
        hasScrobbled = true

        // Last.fm
        if isLastfmAuthenticated, let session = lastfmSession {
            var params: [String: String] = [
                "method":    "track.scrobble",
                "api_key":   lfmApiKey,
                "sk":        session,
                "artist":    track.artist?.name ?? "Unknown Artist",
                "track":     track.title,
                "timestamp": "\(Int(Date().timeIntervalSince1970))",
            ]
            if let album = track.album?.title { params["album"] = album }
            if track.duration > 0 { params["duration"] = "\(track.duration)" }
            params["api_sig"] = generateSignature(params: params)
            params["format"]  = "json"
            _ = try? await lfmPost(params: params)
            print("[Scrobbling] Last.fm scrobbled: \(track.title)")
        }

        // ListenBrainz
        if isListenBrainzAuthenticated, let token = listenBrainzToken {
            await submitListenBrainz(track: track, token: token, listenType: "single")
            print("[Scrobbling] ListenBrainz scrobbled: \(track.title)")
        }
    }

    // MARK: - Last.fm Auth (mobile session — username/password flow)

    func authenticateLastfm(username: String, password: String) async throws {
        await MainActor.run { isAuthenticating = true }
        defer { Task { await MainActor.run { self.isAuthenticating = false } } }

        var params: [String: String] = [
            "method":   "auth.getMobileSession",
            "api_key":  lfmApiKey,
            "username": username,
            "password": password,
            "format":   "json",
        ]
        // Signature is computed WITHOUT format
        var sigParams = params
        sigParams.removeValue(forKey: "format")
        params["api_sig"] = generateSignature(params: sigParams)

        let data = try await lfmPost(params: params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let session = json?["session"] as? [String: Any],
              let key  = session["key"] as? String,
              let name = session["name"] as? String else {
            let msg = (json?["message"] as? String) ?? "Authentication failed"
            throw ScrobblingError.authFailed(msg)
        }

        await MainActor.run {
            self.saveLastfmSession(key: key, username: name)
            self.lastfmEnabled = true
            UserDefaults.standard.set(true, forKey: self.lastfmEnabledKey)
        }
    }

    // MARK: - Signature generation (same as web app's generateSignature)

    private func generateSignature(params: [String: String]) -> String {
        var filtered = params
        filtered.removeValue(forKey: "format")
        filtered.removeValue(forKey: "callback")

        let sorted = filtered.sorted { $0.key < $1.key }
        let raw = sorted.map { "\($0.key)\($0.value)" }.joined() + lfmApiSecret

        // MD5 using CryptoKit via Insecure (fine — Last.fm mandates MD5)
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private func lfmPost(params: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: lfmApiUrl)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: - ListenBrainz

    private func submitListenBrainz(track: Track, token: String, listenType: String) async {
        var additionalInfo: [String: Any] = [
            "submission_client": "Monochrome iOS",
            "media_player": "Monochrome",
        ]
        if let isrc = track.isrc { additionalInfo["isrc"] = isrc }
        if let tn = track.trackNumber { additionalInfo["tracknumber"] = tn }
        if track.duration > 0 { additionalInfo["duration_ms"] = track.duration * 1000 }

        let trackMeta: [String: Any] = [
            "artist_name":           track.artist?.name ?? "Unknown Artist",
            "track_name":            track.title,
            "release_name":          track.album?.title ?? "",
            "additional_info":       additionalInfo,
        ]

        let payload: [String: Any] = [
            "listen_type": listenType,
            "payload": [[
                "listened_at": Int(Date().timeIntervalSince1970),
                "track_metadata": trackMeta,
            ]]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/submit-listens")!)
        req.httpMethod  = "POST"
        req.httpBody    = body
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Token \(token)",    forHTTPHeaderField: "Authorization")

        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Error

enum ScrobblingError: LocalizedError {
    case authFailed(String)
    var errorDescription: String? {
        if case .authFailed(let msg) = self { return msg }
        return nil
    }
}
