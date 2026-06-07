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

    func fetchMix(id: String) async throws -> MixItem {
        guard let data = try? await fetchData(path: "/mix/?id=\\(id)") else {
            return MixItem(id: id, title: nil, images: nil)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let title = (json?["data"] as? [String: Any])?["title"] as? String
            ?? (json?["data"] as? [String: Any])?["mixName"] as? String
        var images: [MixItem.MixImage] = []
        if let imgArr = (json?["data"] as? [String: Any])?["images"] as? [[String: Any]] {
            images = imgArr.compactMap { dict in
                guard let url = dict["url"] as? String else { return nil }
                return MixItem.MixImage(url: url, width: dict["width"] as? Int, height: dict["height"] as? Int)
            }
        }
        return MixItem(id: id, title: title, images: images.isEmpty ? nil : images)
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
    # Strip everything from first marker to (but not including) class end / Detail Models
    idx = content.index(MARKER)
    before = content[:idx].rstrip()
    
    # Find the detail models section that comes after the class closing brace
    if CLASS_END_MARKER in content:
        after_idx = content.index(CLASS_END_MARKER)
        after = content[after_idx:]  # includes \n}\n\n// MARK: - Detail Models...
    else:
        after = "\n}"
    
    content = before + "\n" + ADDITION + "\n}" + after[len("\n}\n\n// MARK: - Detail Models"):]
    if CLASS_END_MARKER in content[len(before):]:
        pass  # already handled
    else:
        # Rebuild with detail models
        content = before + "\n" + ADDITION + "\n}\n\n// MARK: - Detail Models" + after.split("// MARK: - Detail Models", 1)[-1]

    with open(path, "w") as f:
        f.write(content)
    print(f"✓ Deduplicated: wrote single copy of additions to {path}")
else:
    # No marker found - append fresh
    # Insert before the Detail Models section
    if CLASS_END_MARKER in content:
        idx = content.index(CLASS_END_MARKER)
        content = content[:idx] + "\n" + ADDITION + "\n" + content[idx:]
    else:
        content = content.rstrip("}\n") + "\n" + ADDITION + "\n}\n"

    with open(path, "w") as f:
        f.write(content)
    print(f"✓ Appended fresh additions to {path}")
