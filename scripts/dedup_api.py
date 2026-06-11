#!/usr/bin/env python3
"""
Removes duplicate fetchRecommendations/fetchMix/fetchMixTracks from MonochromeAPI.swift
and writes back a single clean copy. Safe to run multiple times.
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
        let title = dataDict?["title"] as? String ?? dataDict?["mixName"] as? String
        let subTitle = dataDict?["subTitle"] as? String
        let mixType = dataDict?["mixType"] as? String
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
'''

if MARKER in content:
    idx = content.index(MARKER)
    before = content[:idx].rstrip()
    if CLASS_END_MARKER in content:
        after_idx = content.index(CLASS_END_MARKER)
        detail_models = content[after_idx + len(CLASS_END_MARKER):]
        content = before + "\n" + ADDITION + "\n}\n\n// MARK: - Detail Models" + detail_models
    else:
        content = before + "\n" + ADDITION + "\n}\n"
    print(f"Deduplicated: wrote single copy of additions to {path}")
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
