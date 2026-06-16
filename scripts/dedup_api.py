#!/usr/bin/env python3
"""
Replaces the entire // MARK: - Stream URL section in MonochromeAPI.swift
with updated /trackManifests/ streaming logic. Safe to run multiple times.
"""

path = "monochrome/Services/MonochromeAPI.swift"

with open(path, "r") as f:
    content = f.read()

MARKER     = "    // MARK: - Stream URL"
END_MARKER = "\n    // MARK: - Images"

ADDITION = '''
    // MARK: - Stream URL
    //
    // Flow (matches web app /trackManifests/ endpoint):
    //   1. GET /trackManifests/?id=X&quality=Q&formats=F  on streaming instance
    //   2. Response: { data: { attributes: { uri: "https://signed-manifest-url" } } }
    //   3. Fetch that signed URI to get raw manifest (DASH XML or JSON)
    //   4. Extract CDN audio URL from manifest
    //   5. Fall back to old /stream/ path, then Qobuz via ISRC

    // MARK: - Manifest models

    private struct StreamManifestResponse: Codable {
        let data: StreamManifestData?
    }
    private struct StreamManifestData: Codable {
        let attributes: StreamManifestAttributes?
    }
    private struct StreamManifestAttributes: Codable {
        let uri: String?
        let codec: String?
        let bitDepth: Int?
        let sampleRate: Int?
    }

    private struct TidalManifest: Codable {
        let urls: [String]?
        let mimeType: String?
    }

    // MARK: - Qobuz models (fallback)

    private struct QobuzSearchResponse: Codable {
        let data: QobuzSearchData?
    }
    private struct QobuzSearchData: Codable {
        let tracks: QobuzTrackResults?
    }
    private struct QobuzTrackResults: Codable {
        let items: [QobuzTrackItem]?
    }
    private struct QobuzTrackItem: Codable {
        let id: Int
        let isrc: String?
    }
    private struct QobuzDownloadResponse: Codable {
        let success: Bool
        let data: QobuzDownloadData?
    }
    private struct QobuzDownloadData: Codable {
        let url: String?
    }

    // MARK: fetchTrack

    func fetchTrack(id: Int) async throws -> Track {
        let cacheKey = "track_\\(id)"
        if let cached: Track = CacheService.shared.get(forKey: cacheKey), cached.isrc != nil {
            return cached
        }
        guard let url = URL(string: "https://api.tidal.com/v1/tracks/\\(id)?countryCode=GB") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Monochrome-iOS/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("txNoH4kkV41MfH25",  forHTTPHeaderField: "X-Tidal-Token")
        let (data, response) = try await urlSession.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let track = try JSONDecoder().decode(Track.self, from: data)
        CacheService.shared.set(forKey: cacheKey, value: track)
        return track
    }

    // MARK: Primary — /trackManifests/ (new endpoint)

    private func fetchViaTrackManifests(trackId: Int, quality: AudioQuality) async -> String? {
        let qualityStr: String
        switch quality {
        case .hiResLossless: qualityStr = "HI_RES_LOSSLESS"
        case .lossless:      qualityStr = "LOSSLESS"
        case .high:          qualityStr = "HIGH"
        case .medium:        qualityStr = "HIGH"
        case .low:           qualityStr = "LOW"
        }
        let formatStr: String
        switch quality {
        case .hiResLossless: formatStr = "FLAC_HIRES"
        case .lossless:      formatStr = "FLAC"
        default:             formatStr = "AACLC"
        }

        let instances = InstanceManager.shared.getInstances(type: "streaming")
        let bases = instances.isEmpty
            ? ["https://hifi.geeked.wtf", "https://eu-central.monochrome.tf"]
            : instances.map { $0.url.trimmingCharacters(in: .init(charactersIn: "/")) }

        for base in bases {
            guard let url = URL(string: "\\(base)/trackManifests/?id=\\(trackId)&quality=\\(qualityStr)&adaptive=false&formats=\\(formatStr)") else { continue }
            do {
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.setValue("Monochrome-iOS/1.0", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await urlSession.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                // Navigate to attributes.uri — handle both { data: { attributes } } and { attributes }
                let attrs: [String: Any]?
                if let d = json["data"] as? [String: Any] {
                    attrs = d["attributes"] as? [String: Any]
                } else {
                    attrs = json["attributes"] as? [String: Any]
                }

                guard let signedUri = attrs?["uri"] as? String,
                      let manifestURL = URL(string: signedUri) else { continue }

                let (manifestData, manifestResp) = try await urlSession.data(from: manifestURL)
                guard (manifestResp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let manifestText = String(data: manifestData, encoding: .utf8) ?? ""
                let contentType  = (manifestResp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""

                // DASH manifest
                if contentType.contains("dash+xml") || manifestText.contains("<MPD") {
                    if let cdnUrl = extractDashUrl(from: manifestText) {
                        print("[Stream] DASH URL via \\(base)")
                        return cdnUrl
                    }
                    continue
                }

                // JSON manifest — may be base64-encoded
                let jsonText: String
                if let decoded = Data(base64Encoded: manifestText.trimmingCharacters(in: .whitespaces)),
                   let str = String(data: decoded, encoding: .utf8) {
                    jsonText = str
                } else {
                    jsonText = manifestText
                }

                if let jData = jsonText.data(using: .utf8),
                   let manifest = try? JSONDecoder().decode(TidalManifest.self, from: jData),
                   let first = manifest.urls?.first, !first.isEmpty {
                    print("[Stream] JSON manifest URL via \\(base)")
                    return first
                }
            } catch {
                print("[Stream] \\(base) /trackManifests/ failed: \\(error.localizedDescription)")
                continue
            }
        }
        return nil
    }

    // MARK: Legacy — /stream/ (old endpoint, kept as fallback)

    private func fetchViaStreamEndpoint(trackId: Int, quality: AudioQuality) async -> String? {
        let qualityStr: String
        switch quality {
        case .hiResLossless: qualityStr = "HI_RES_LOSSLESS"
        case .lossless:      qualityStr = "LOSSLESS"
        case .high:          qualityStr = "HIGH"
        case .medium:        qualityStr = "HIGH"
        case .low:           qualityStr = "LOW"
        }
        let instances = InstanceManager.shared.getInstances(type: "streaming")
        let bases = instances.isEmpty
            ? ["https://hifi.geeked.wtf", "https://eu-central.monochrome.tf"]
            : instances.map { $0.url.trimmingCharacters(in: .init(charactersIn: "/")) }

        for base in bases {
            guard let url = URL(string: "\\(base)/stream/?id=\\(trackId)&quality=\\(qualityStr)") else { continue }
            do {
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.setValue("Monochrome-iOS/1.0", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await urlSession.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let b64 = json["manifest"] as? String,
                      let manifestData = Data(base64Encoded: b64),
                      let manifest = try? JSONDecoder().decode(TidalManifest.self, from: manifestData),
                      let first = manifest.urls?.first, !first.isEmpty else { continue }
                print("[Stream] /stream/ URL via \\(base)")
                return first
            } catch { continue }
        }
        return nil
    }

    // MARK: DASH helper

    private func extractDashUrl(from xml: String) -> String? {
        let openTag  = "<BaseURL>"
        let closeTag = "</BaseURL>"
        if let s = xml.range(of: openTag),
           let e = xml.range(of: closeTag, range: s.upperBound..<xml.endIndex) {
            let url = String(xml[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasPrefix("http") { return url }
        }
        // Look for initialization= attribute
        let needle = "initialization="
        if let ns = xml.range(of: needle) {
            let rest = xml[ns.upperBound...]
            if let firstChar = rest.first {
                let afterQuote = rest.dropFirst()
                if let qEnd = afterQuote.firstIndex(of: firstChar) {
                    let url = String(afterQuote[..<qEnd])
                    if url.hasPrefix("http") { return url }
                }
            }
        }
        return nil
    }

    // MARK: Qobuz fallback

    private func fetchViaQobuz(trackId: Int, quality: AudioQuality) async -> String? {
        guard let track = try? await fetchTrack(id: trackId),
              let isrc = track.isrc, !isrc.isEmpty else { return nil }

        let instances = InstanceManager.shared.getInstances(type: "qobuz")
        guard !instances.isEmpty else { return nil }

        let qQuality: Int
        switch quality {
        case .hiResLossless: qQuality = 27
        case .lossless:      qQuality = 6
        default:             qQuality = 5
        }

        for instance in instances {
            let base = instance.url.trimmingCharacters(in: .init(charactersIn: "/"))
            guard let searchURL = URL(string: "\\(base)/api/get-music?q=\\(isrc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? isrc)&offset=0") else { continue }
            do {
                let (searchData, searchResp) = try await urlSession.data(from: searchURL)
                guard (searchResp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let decoded = try JSONDecoder().decode(QobuzSearchResponse.self, from: searchData)
                let items = decoded.data?.tracks?.items ?? []
                guard let match = items.first(where: { $0.isrc?.lowercased() == isrc.lowercased() }) ?? items.first else { continue }
                guard let dlURL = URL(string: "\\(base)/api/download-music?track_id=\\(match.id)&quality=\\(qQuality)") else { continue }
                let (dlData, dlResp) = try await urlSession.data(from: dlURL)
                guard (dlResp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let dl = try JSONDecoder().decode(QobuzDownloadResponse.self, from: dlData)
                if dl.success, let url = dl.data?.url, !url.isEmpty {
                    print("[Stream] Qobuz URL via \\(base)")
                    return url
                }
            } catch { continue }
        }
        return nil
    }

    // MARK: Public API

    func fetchStreamUrlWithFallback(trackId: Int, preferredQuality: AudioQuality) async -> String? {
        let order: [AudioQuality] = ([preferredQuality] + [.hiResLossless, .lossless, .high, .medium, .low].filter { $0 != preferredQuality })

        // 1. Try new /trackManifests/ endpoint
        for quality in order {
            if let url = await fetchViaTrackManifests(trackId: trackId, quality: quality) { return url }
        }
        // 2. Fall back to legacy /stream/ endpoint
        for quality in order {
            if let url = await fetchViaStreamEndpoint(trackId: trackId, quality: quality) { return url }
        }
        // 3. Qobuz last resort
        if let url = await fetchViaQobuz(trackId: trackId, quality: preferredQuality) { return url }

        print("[Stream] All sources exhausted for track \\(trackId)")
        return nil
    }

    func fetchStreamUrl(trackId: Int, quality: AudioQuality = .high) async throws -> String? {
        await fetchStreamUrlWithFallback(trackId: trackId, preferredQuality: quality)
    }

'''

# Replace entire stream section
if MARKER in content and END_MARKER in content:
    start = content.index(MARKER)
    end   = content.index(END_MARKER)
    content = content[:start] + ADDITION + content[end:]
    print(f"Replaced stream section in {path}")
elif MARKER in content:
    # No Images marker - replace to class end
    start = content.index(MARKER)
    class_end = content.rfind("\n}\n")
    content = content[:start] + ADDITION + "\n}\n"
    print(f"Replaced stream section (no Images marker) in {path}")
else:
    # Insert before Images section
    if END_MARKER in content:
        end = content.index(END_MARKER)
        content = content[:end] + ADDITION + content[end:]
    else:
        content = content.rstrip().rstrip("}") + "\n" + ADDITION + "\n}\n"
    print(f"Inserted stream section in {path}")

# Add Infinite Radio / Mix / Recommendations before Images
RADIO_MARKER  = "    // MARK: - Infinite Radio"
RADIO_ADDITION = '''
    // MARK: - Infinite Radio / Recommendations

    func fetchRecommendations(trackId: Int) async throws -> [Track] {
        guard let data = (try? await fetchData(path: "/recommendations/?id=\\(trackId)")) else { return [] }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let items = dataDict["items"] as? [[String: Any]],
           let arrData = try? JSONSerialization.data(withJSONObject: items),
           let tracks = try? JSONDecoder().decode([Track].self, from: arrData) { return tracks }
        return []
    }

    func fetchMix(id: String) async throws -> Mix {
        guard let data = try? await fetchData(path: "/mix/?id=\\(id)") else {
            return Mix(id: id, title: nil, subTitle: nil, mixType: nil, cover: nil)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let d = json?["data"] as? [String: Any]
        let cover: String?
        if let imgs = d?["images"] as? [[String: Any]], let u = imgs.first?["url"] as? String { cover = u }
        else { cover = d?["cover"] as? String }
        return Mix(id: id, title: d?["title"] as? String ?? d?["mixName"] as? String,
                   subTitle: d?["subTitle"] as? String, mixType: d?["mixType"] as? String, cover: cover)
    }

    func fetchMixTracks(id: String) async throws -> [Track] {
        guard let data = try? await fetchData(path: "/mix/?id=\\(id)") else { return [] }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let d = json?["data"] as? [String: Any],
              let items = (d["tracks"] as? [[String: Any]]) ?? (d["items"] as? [[String: Any]]),
              let arrData = try? JSONSerialization.data(withJSONObject: items) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: arrData)) ?? []
    }

'''

# Strip any stale MixItem / old mix functions anywhere in the file first
stale_markers = [
    "    private struct MixDetail",
    "    func fetchMix(id: String) async throws -> MixItem",
    "    func fetchMixTracks(id: String) async throws -> MixItem",
]
for sm in stale_markers:
    while sm in content:
        s = content.index(sm)
        # Skip forward to find the opening '{' of the function/struct body
        i = s
        while i < len(content) and content[i] != "{":
            i += 1
        # Now count braces from the first '{' to find the matching '}'
        depth = 0
        found_end = len(content)
        while i < len(content):
            if content[i] == "{":
                depth += 1
            elif content[i] == "}":
                depth -= 1
                if depth == 0:
                    found_end = i + 1
                    break
            i += 1
        # Remove trailing newlines after the stripped block too
        while found_end < len(content) and content[found_end] in ("\n", "\r"):
            found_end += 1
        content = content[:s].rstrip() + "\n" + content[found_end:]
        print(f"Stripped: {sm[:50]}")

# Always strip existing Radio/Mix section and reinsert clean version
if RADIO_MARKER in content:
    r_start = content.index(RADIO_MARKER)
    # Find end of this section (next MARK or Images)
    search_from = r_start + len(RADIO_MARKER)
    section_end = len(content)
    for candidate in ["\n    // MARK: - Images", "\n    func getImageUrl"]:
        pos = content.find(candidate, search_from)
        if 0 < pos < section_end:
            section_end = pos
    content = content[:r_start].rstrip() + "\n" + content[section_end:]
    print("Stripped existing Radio section")

if END_MARKER in content:
    end = content.index(END_MARKER)
    content = content[:end] + RADIO_ADDITION + content[end:]
    print("Inserted fresh Radio/Mix/Recommendations section")

with open(path, "w") as f:
    f.write(content)
