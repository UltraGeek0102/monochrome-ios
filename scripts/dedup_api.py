#!/usr/bin/env python3
"""
Removes duplicate fetchRecommendations/fetchMix/fetchMixTracks/fetchTidalStreamUrl
from MonochromeAPI.swift and writes back a single clean copy.
Safe to run multiple times.

Stream API updated to match web app's /trackManifests/ endpoint (replaces old /stream/).
"""

path = "monochrome/Services/MonochromeAPI.swift"

with open(path, "r") as f:
    content = f.read()

MARKER = "    // MARK: - Infinite Radio"
CLASS_END_MARKER = "\n}\n\n// MARK: - Detail Models"

ADDITION = '''
    // MARK: - Infinite Radio / Recommendations

    func fetchRecommendations(trackId: Int) async throws -> [Track] {
        guard let data = try? await fetchData(path: "/recommendations/?id=\\(trackId)") else { return [] }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataDict = json["data"] as? [String: Any],
           let items = dataDict["items"] as? [[String: Any]],
           let arrData = try? JSONSerialization.data(withJSONObject: items),
           let tracks = try? JSONDecoder().decode([Track].self, from: arrData) {
            return tracks
        }
        return []
    }

    // MARK: - Mix

    func fetchMix(id: String) async throws -> Mix {
        guard let data = try? await fetchData(path: "/mix/?id=\\(id)") else {
            return Mix(id: id, title: nil, subTitle: nil, mixType: nil, cover: nil)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataDict = json?["data"] as? [String: Any]
        let title    = dataDict?["title"]   as? String ?? dataDict?["mixName"] as? String
        let subTitle = dataDict?["subTitle"] as? String
        let mixType  = dataDict?["mixType"]  as? String
        let cover: String?
        if let images = dataDict?["images"] as? [[String: Any]],
           let first = images.first,
           let url = first["url"] as? String {
            cover = url
        } else {
            cover = dataDict?["cover"] as? String
        }
        return Mix(id: id, title: title, subTitle: subTitle, mixType: mixType, cover: cover)
    }

    func fetchMixTracks(id: String) async throws -> [Track] {
        guard let data = try? await fetchData(path: "/mix/?id=\\(id)") else { return [] }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let dataDict = json?["data"] as? [String: Any],
              let items = (dataDict["tracks"] as? [[String: Any]]) ?? (dataDict["items"] as? [[String: Any]]),
              let arrData = try? JSONSerialization.data(withJSONObject: items) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: arrData)) ?? []
    }

    // MARK: - Stream URL (matches web app /trackManifests/ endpoint)
    //
    // Flow (mirrors api.js getStreamUrl / normalizeTrackManifestResponse):
    //   1. GET /trackManifests/?id=X&quality=LOSSLESS&formats=FLAC  on a streaming instance
    //   2. Response: { data: { attributes: { uri: "https://signed-manifest-url", ... } } }
    //   3. Fetch the signed URI → get raw manifest text
    //   4. If DASH XML (<MPD): extract BaseURL / SegmentTemplate from first AdaptationSet
    //   5. If JSON: parse { urls: ["https://cdn-url.flac"] }
    //   6. If base64: decode then parse as JSON

    func fetchTidalStreamUrl(trackId: Int, quality: AudioQuality) async -> String? {
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
            : instances.map { $0.url }

        for base in bases {
            let path = "/trackManifests/?id=\\(trackId)&quality=\\(qualityStr)&adaptive=false&formats=\\(formatStr)"
            guard let url = URL(string: "\\(base)\\(path)") else { continue }

            do {
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.setValue("Monochrome-iOS/1.0", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }

                // Parse: { data: { attributes: { uri: "...", formats: [...] } } }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let raw = (json["data"] as? [String: Any])?["data"]
                       ?? json["data"]
                       ?? json
                guard let attributes = (raw as? [String: Any])?["attributes"] as? [String: Any],
                      let signedUri = attributes["uri"] as? String,
                      let manifestURL = URL(string: signedUri) else { continue }

                // Fetch the signed manifest
                let (manifestData, manifestResp) = try await URLSession.shared.data(from: manifestURL)
                guard (manifestResp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let manifestText = String(data: manifestData, encoding: .utf8) ?? ""
                let contentType  = (manifestResp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""

                // DASH manifest
                if contentType.contains("dash+xml") || manifestText.contains("<MPD") {
                    if let cdnUrl = extractDashUrl(from: manifestText) {
                        print("[Stream] DASH CDN URL via \\(base)")
                        return cdnUrl
                    }
                    continue
                }

                // JSON manifest (may be raw or base64-encoded)
                let jsonText: String
                if let decoded = Data(base64Encoded: manifestText.trimmingCharacters(in: .whitespaces)),
                   let decodedStr = String(data: decoded, encoding: .utf8) {
                    jsonText = decodedStr
                } else {
                    jsonText = manifestText
                }

                if let jsonData = jsonText.data(using: .utf8),
                   let manifest = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let urls = manifest["urls"] as? [String],
                   let first = urls.first, !first.isEmpty {
                    print("[Stream] JSON manifest URL via \\(base)")
                    return first
                }

            } catch {
                print("[Stream] Instance \\(base) failed: \\(error.localizedDescription)")
                continue
            }
        }
        return nil
    }

    private func extractDashUrl(from xml: String) -> String? {
        // Look for <BaseURL>https://...</BaseURL>
        let openTag  = "<BaseURL>"
        let closeTag = "</BaseURL>"
        if let s = xml.range(of: openTag),
           let e = xml.range(of: closeTag, range: s.upperBound..<xml.endIndex) {
            let url = String(xml[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasPrefix("http") { return url }
        }
        // Fallback: look for initialization= followed by a quoted URL
        let needle = "initialization="
        guard let ns = xml.range(of: needle) else { return nil }
        let rest = xml[ns.upperBound...]
        // rest starts with either " or ' followed by the URL
        guard let firstChar = rest.first else { return nil }
        let afterQuote = rest.dropFirst()
        if let qEnd = afterQuote.firstIndex(of: firstChar) {
            let url = String(afterQuote[..<qEnd])
            if url.hasPrefix("http") { return url }
        }
        return nil
    }


    func fetchStreamUrlWithFallback(trackId: Int, preferredQuality: AudioQuality) async -> String? {
        let order: [AudioQuality] = [preferredQuality] + [.hiResLossless, .lossless, .high, .medium, .low]
            .filter { $0 != preferredQuality }

        for quality in order {
            if let url = await fetchTidalStreamUrl(trackId: trackId, quality: quality) {
                if quality != preferredQuality {
                    print("[Stream] Fell back from \\(preferredQuality) to \\(quality)")
                }
                return url
            }
        }

        // Last resort: Qobuz fallback
        print("[Stream] All /trackManifests/ instances failed, trying Qobuz...")
        if let url = try? await fetchStreamUrl(trackId: trackId, quality: preferredQuality) {
            return url
        }

        print("[Stream] All sources failed for track \\(trackId)")
        return nil
    }
'''

# Also strip old stream functions that may exist before our MARKER
stream_markers = [
    "    // MARK: - Stream URL",
    "    private func fetchTidalStreamUrl(",
    "    func fetchTidalStreamUrl(",
    "    func fetchStreamUrlWithFallback(",
]
for sm in stream_markers:
    if sm in content and (MARKER not in content or content.index(sm) < content.index(MARKER)):
        # Remove from this marker to the next top-level func or our MARKER
        idx = content.index(sm)
        # Find the end: next "    func " or "    // MARK:" at same indent level
        search_from = idx + len(sm)
        next_func = len(content)
        for candidate in ["\n    func ", "\n    // MARK: -", "\n    private func fetchQ"]:
            pos = content.find(candidate, search_from)
            if pos > 0 and pos < next_func:
                next_func = pos
        content = content[:idx].rstrip() + "\n" + content[next_func:]

if MARKER in content:
    idx = content.index(MARKER)
    before = content[:idx].rstrip()
    if CLASS_END_MARKER in content:
        after_idx = content.index(CLASS_END_MARKER)
        detail_models = content[after_idx + len(CLASS_END_MARKER):]
        content = before + "\n" + ADDITION + "\n}\n\n// MARK: - Detail Models" + detail_models
    else:
        content = before + "\n" + ADDITION + "\n}\n"
    print(f"Deduplicated: wrote single clean copy to {path}")
else:
    if CLASS_END_MARKER in content:
        idx = content.index(CLASS_END_MARKER)
        detail_models = content[idx + len(CLASS_END_MARKER):]
        content = content[:idx] + "\n" + ADDITION + "\n}\n\n// MARK: - Detail Models" + detail_models
    else:
        content = content.rstrip().rstrip("}") + "\n" + ADDITION + "\n}\n"
    print(f"Appended fresh additions to {path}")

with open(path, "w") as f:
    f.write(content)
