import SwiftUI
import Combine

// MARK: - Last.fm API key (already used by ScrobblingService)
private let lfmKey = "85214f5abbc730e78770f27784b9bdf7"

// MARK: - Last.fm tag → genre ID mapping
private let lfmTagMap: [String: String] = [
    "hip_hop":          "hip-hop",
    "rnb":              "rnb",
    "pop":              "pop",
    "indierock":        "indie",
    "dance_electronic": "electronic",
    "jazz":             "jazz",
    "classical":        "classical",
    "metal":            "metal",
    "latin":            "latin",
    "reggae":           "reggae",
    "country":          "country",
    "blues":            "blues",
    "kpop":             "k-pop",
    "americana":        "folk",
    "world":            "world",
    "gospel":           "gospel",
    "retro":            "classic rock",
    "kids":             "children",
]

// MARK: - Explore API Models

struct ExploreResponse: Decodable {
    let top_albums: [ExploreAlbum]?
    let top_tracks: [ExploreTrack]?
    let featured_playlists: [ExplorePlaylist]?
    let sections: [ExploreSection]?
}

struct ExploreTrack: Identifiable, Decodable {
    let id: Int
    let title: String
    let artist: ExploreArtistRef?
    let album: ExploreAlbumRef?
    struct ExploreArtistRef: Decodable { let name: String? }
    struct ExploreAlbumRef: Decodable { let cover: String?; let title: String? }
    var artistName: String { artist?.name ?? "Unknown Artist" }
    var coverUrl: URL? {
        guard let cover = album?.cover else { return nil }
        let fmt = cover.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(fmt)/320x320.jpg")
    }
}

struct ExploreAlbum: Identifiable, Decodable {
    let id: Int
    let title: String
    let cover: String?
    let artist: ExploreArtistSimple?
    struct ExploreArtistSimple: Decodable { let name: String? }
    var coverUrl: URL? {
        guard let c = cover else { return nil }
        let fmt = c.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(fmt)/320x320.jpg")
    }
}

struct ExplorePlaylist: Identifiable, Decodable {
    let uuid: String
    let title: String
    let image: String?
    var id: String { uuid }
    var coverUrl: URL? { image.flatMap { URL(string: $0) } }
}

struct ExploreSection: Decodable {
    let title: String?
    let type: String?
    let items: [ExploreSectionItem]?
}

struct ExploreSectionItem: Decodable {
    let id: Int?
    let uuid: String?
    let title: String?
    let cover: String?
    let image: String?
    let artist: ExploreTrack.ExploreArtistRef?
    var coverUrl: URL? {
        let src = cover ?? image
        guard let s = src else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        let fmt = s.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(fmt)/320x320.jpg")
    }
}

// MARK: - Last.fm models

struct LfmTrack: Identifiable {
    let id = UUID()
    let name: String
    let artist: String
    let imageUrl: URL?
    let playcount: String?
}

struct LfmAlbum: Identifiable {
    let id = UUID()
    let name: String
    let artist: String
    let imageUrl: URL?
}

struct LfmArtist: Identifiable {
    let id = UUID()
    let name: String
    let imageUrl: URL?
    let listeners: String?
}

// MARK: - Genre Model

struct ExploreGenre: Identifiable {
    let id: String       // monochrome genre id
    let name: String
    var lfmTag: String { lfmTagMap[id] ?? id.replacingOccurrences(of: "_", with: "-") }
}

// MARK: - Main ExploreViewModel

@MainActor
class ExploreViewModel: ObservableObject {
    @Published var trendingTracks: [ExploreTrack] = []
    @Published var trendingAlbums: [ExploreAlbum] = []
    @Published var featuredPlaylists: [ExplorePlaylist] = []
    @Published var extraSections: [ExploreSection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    let genres: [ExploreGenre] = [
        .init(id: "hip_hop",          name: "Hip-Hop"),
        .init(id: "rnb",              name: "R&B / Soul"),
        .init(id: "pop",              name: "Pop"),
        .init(id: "indierock",        name: "Rock / Indie"),
        .init(id: "dance_electronic", name: "Electronic"),
        .init(id: "jazz",             name: "Jazz"),
        .init(id: "classical",        name: "Classical"),
        .init(id: "metal",            name: "Metal"),
        .init(id: "latin",            name: "Latin"),
        .init(id: "reggae",           name: "Reggae"),
        .init(id: "country",          name: "Country"),
        .init(id: "blues",            name: "Blues"),
        .init(id: "kpop",             name: "K-Pop"),
        .init(id: "americana",        name: "Folk"),
        .init(id: "world",            name: "Global"),
        .init(id: "gospel",           name: "Gospel"),
        .init(id: "retro",            name: "Classic Rock"),
        .init(id: "kids",             name: "Kids"),
    ]

    func load() async {
        guard trendingTracks.isEmpty && trendingAlbums.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let url = URL(string: "https://hot.monochrome.tf/")!
            var req = URLRequest(url: url)
            req.setValue("Monochrome-iOS/1.0", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                errorMessage = "Explore unavailable"
                return
            }
            let decoded = try JSONDecoder().decode(ExploreResponse.self, from: data)
            trendingTracks    = decoded.top_tracks         ?? []
            trendingAlbums    = decoded.top_albums         ?? []
            featuredPlaylists = decoded.featured_playlists ?? []
            extraSections     = decoded.sections?.filter { ($0.items?.count ?? 0) > 0 } ?? []
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
    }
}

// MARK: - Genre ViewModel (Last.fm powered)

@MainActor
class GenreViewModel: ObservableObject {
    @Published var topTracks: [LfmTrack] = []
    @Published var topAlbums: [LfmAlbum] = []
    @Published var topArtists: [LfmArtist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let tag: String

    init(tag: String) { self.tag = tag }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let tracks  = fetchTopTracks()
        async let albums  = fetchTopAlbums()
        async let artists = fetchTopArtists()

        topTracks  = (await tracks)  ?? []
        topAlbums  = (await albums)  ?? []
        topArtists = (await artists) ?? []

        if topTracks.isEmpty && topAlbums.isEmpty && topArtists.isEmpty {
            errorMessage = "No results found for this genre."
        }
    }

    private func fetchTopTracks() async -> [LfmTrack]? {
        guard let url = URL(string: "https://ws.audioscrobbler.com/2.0/?method=tag.gettoptracks&tag=\(tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag)&api_key=\(lfmKey)&format=json&limit=20") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = (json["tracks"] as? [String: Any])?["track"] as? [[String: Any]] else { return nil }
        return tracks.compactMap { t in
            let name   = t["name"] as? String ?? ""
            let artist = (t["artist"] as? [String: Any])?["name"] as? String ?? ""
            let images = t["image"] as? [[String: Any]] ?? []
            let imgUrl = images.last(where: { ($0["size"] as? String) == "extralarge" })?["#text"] as? String
                      ?? images.last?["#text"] as? String
            return LfmTrack(name: name, artist: artist,
                            imageUrl: imgUrl.flatMap { URL(string: $0) },
                            playcount: t["playcount"] as? String)
        }.filter { !$0.name.isEmpty }
    }

    private func fetchTopAlbums() async -> [LfmAlbum]? {
        guard let url = URL(string: "https://ws.audioscrobbler.com/2.0/?method=tag.gettopalbums&tag=\(tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag)&api_key=\(lfmKey)&format=json&limit=20") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let albums = (json["albums"] as? [String: Any])?["album"] as? [[String: Any]] else { return nil }
        return albums.compactMap { a in
            let name   = a["name"] as? String ?? ""
            let artist = (a["artist"] as? [String: Any])?["name"] as? String ?? ""
            let images = a["image"] as? [[String: Any]] ?? []
            let imgUrl = images.last(where: { ($0["size"] as? String) == "extralarge" })?["#text"] as? String
                      ?? images.last?["#text"] as? String
            return LfmAlbum(name: name, artist: artist,
                            imageUrl: imgUrl.flatMap { URL(string: $0) })
        }.filter { !$0.name.isEmpty }
    }

    private func fetchTopArtists() async -> [LfmArtist]? {
        guard let url = URL(string: "https://ws.audioscrobbler.com/2.0/?method=tag.gettopartists&tag=\(tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag)&api_key=\(lfmKey)&format=json&limit=20") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artists = (json["topartists"] as? [String: Any])?["artist"] as? [[String: Any]] else { return nil }
        return artists.compactMap { a in
            let name   = a["name"] as? String ?? ""
            let images = a["image"] as? [[String: Any]] ?? []
            let imgUrl = images.last(where: { ($0["size"] as? String) == "extralarge" })?["#text"] as? String
                      ?? images.last?["#text"] as? String
            return LfmArtist(name: name,
                             imageUrl: imgUrl.flatMap { URL(string: $0) },
                             listeners: a["listeners"] as? String)
        }.filter { !$0.name.isEmpty }
    }
}

// MARK: - ExploreView

struct ExploreView: View {
    @Binding var navigationPath: CompatNavigationPath
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @StateObject private var vm = ExploreViewModel()
    @State private var selectedGenre: ExploreGenre? = nil

    var body: some View {
        Group {
            if let genre = selectedGenre {
                GenreView(genre: genre, navigationPath: $navigationPath) {
                    selectedGenre = nil
                }
            } else {
                mainExploreView
            }
        }
        .background(Theme.background)
        .task { await vm.load() }
    }

    private var mainExploreView: some View {
        ScrollView {
            if vm.isLoading {
                loadingView
            } else if let error = vm.errorMessage {
                Text(error)
                    .foregroundColor(Theme.mutedForeground)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .padding(40)
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    genresSection

                    if !vm.trendingTracks.isEmpty {
                        exploreSection(title: "Trending Tracks") {
                            ForEach(vm.trendingTracks.prefix(20)) { track in
                                ExploreTrackCard(track: track) { playTrack(id: track.id) }
                            }
                        }
                    }

                    if !vm.trendingAlbums.isEmpty {
                        exploreSection(title: "Trending Albums") {
                            ForEach(vm.trendingAlbums.prefix(20)) { album in
                                ExploreItemCard(
                                    title: album.title,
                                    subtitle: album.artist?.name ?? "",
                                    coverUrl: album.coverUrl
                                ) {
                                    navigationPath.append(Album(id: album.id, title: album.title,
                                        cover: album.cover, numberOfTracks: nil,
                                        releaseDate: nil, artist: nil, type: nil))
                                }
                            }
                        }
                    }

                    if !vm.featuredPlaylists.isEmpty {
                        exploreSection(title: "Featured Playlists") {
                            ForEach(vm.featuredPlaylists.prefix(20)) { pl in
                                ExploreItemCard(title: pl.title, subtitle: "Playlist", coverUrl: pl.coverUrl) {}
                            }
                        }
                    }

                    ForEach(vm.extraSections.indices, id: \.self) { i in
                        let section = vm.extraSections[i]
                        if let items = section.items, !items.isEmpty {
                            exploreSection(title: section.title ?? "More") {
                                ForEach(items.prefix(20).indices, id: \.self) { j in
                                    let item = items[j]
                                    ExploreItemCard(
                                        title: item.title ?? "",
                                        subtitle: item.artist?.name ?? "",
                                        coverUrl: item.coverUrl
                                    ) {}
                                }
                            }
                        }
                    }

                    Color.clear.frame(height: 100)
                }
                .padding(.top, 16)
            }
        }
    }

    // MARK: - Genres grid

    private var genresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genres")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.foreground)
                .padding(.horizontal, 16)

            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(vm.genres) { genre in
                    Button { selectedGenre = genre } label: {
                        Text(genre.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.foreground)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Section wrapper

    private func exploreSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.foreground)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { content() }
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Loading skeleton

    private var loadingView: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonPill(width: 140, height: 16).padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(0..<6, id: \.self) { _ in
                                SkeletonPill(width: 130, height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            Color.clear.frame(height: 100)
        }
        .padding(.top, 16)
    }

    private func playTrack(id: Int) {
        Task {
            if let track = try? await MonochromeAPI().fetchTrack(id: id) {
                audioPlayer.play(track: track)
            }
        }
    }
}

// MARK: - GenreView (Last.fm powered)

struct GenreView: View {
    let genre: ExploreGenre
    @Binding var navigationPath: CompatNavigationPath
    let onBack: () -> Void

    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @StateObject private var vm: GenreViewModel
    @State private var selectedTab: GenreTab = .tracks

    enum GenreTab: String, CaseIterable {
        case tracks = "Tracks"
        case albums = "Albums"
        case artists = "Artists"
    }

    init(genre: ExploreGenre, navigationPath: Binding<CompatNavigationPath>, onBack: @escaping () -> Void) {
        self.genre = genre
        self._navigationPath = navigationPath
        self.onBack = onBack
        self._vm = StateObject(wrappedValue: GenreViewModel(tag: lfmTagMap[genre.id] ?? genre.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.foreground)
                        .frame(width: 36, height: 36)
                        .background(Theme.secondary)
                        .clipShape(Circle())
                }

                Text(genre.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.foreground)

                Spacer()

                // Last.fm badge
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                    Text("Last.fm")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(Theme.mutedForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.secondary)
                .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Tab picker
            HStack(spacing: 0) {
                ForEach(GenreTab.allCases, id: \.self) { tab in
                    Button { withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab } } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(selectedTab == tab ? Theme.foreground : Theme.mutedForeground)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    }
                    .background(
                        VStack {
                            Spacer()
                            if selectedTab == tab {
                                Rectangle().fill(Theme.foreground).frame(height: 2)
                            }
                        }
                    )
                }
            }
            .overlay(Divider().background(Theme.secondary), alignment: .bottom)

            // Content
            if vm.isLoading {
                Spacer()
                ProgressView().tint(Theme.mutedForeground)
                Spacer()
            } else if let error = vm.errorMessage {
                Spacer()
                Text(error)
                    .foregroundColor(Theme.mutedForeground)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .padding(40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        switch selectedTab {
                        case .tracks:  tracksContent
                        case .albums:  albumsContent
                        case .artists: artistsContent
                        }
                        Color.clear.frame(height: 100)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .background(Theme.background)
        .task { await vm.load() }
    }

    // MARK: - Tracks

    private var tracksContent: some View {
        ForEach(vm.topTracks) { track in
            Button {
                // Search TIDAL for this track and play it
                Task { await searchAndPlay(trackName: track.name, artistName: track.artist) }
            } label: {
                HStack(spacing: 12) {
                    CachedAsyncImage(url: track.imageUrl) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Theme.secondary)
                                .overlay(Image(systemName: "music.note")
                                    .foregroundColor(Theme.mutedForeground.opacity(0.5)))
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Theme.foreground)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.mutedForeground)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let plays = track.playcount, let n = Int(plays), n > 0 {
                        Text(formatCount(n))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.mutedForeground)
                    }

                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.mutedForeground.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().background(Theme.border).padding(.leading, 76)
        }
    }

    // MARK: - Albums

    private var albumsContent: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ForEach(vm.topAlbums) { album in
                VStack(alignment: .leading, spacing: 6) {
                    CachedAsyncImage(url: album.imageUrl) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Theme.secondary)
                                .overlay(Image(systemName: "square.stack")
                                    .foregroundColor(Theme.mutedForeground.opacity(0.5)))
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(album.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.foreground)
                        .lineLimit(1)

                    Text(album.artist)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.mutedForeground)
                        .lineLimit(1)
                }
                .onTapGesture {
                    Task { await searchAndOpenAlbum(albumName: album.name, artistName: album.artist) }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Artists

    private var artistsContent: some View {
        ForEach(vm.topArtists) { artist in
            Button {
                Task { await searchAndOpenArtist(artistName: artist.name) }
            } label: {
                HStack(spacing: 14) {
                    CachedAsyncImage(url: artist.imageUrl) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Circle().fill(Theme.secondary)
                                .overlay(Image(systemName: "person.fill")
                                    .foregroundColor(Theme.mutedForeground.opacity(0.5)))
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(artist.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Theme.foreground)
                        if let listeners = artist.listeners, let n = Int(listeners), n > 0 {
                            Text("\(formatCount(n)) listeners")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.mutedForeground)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.mutedForeground.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().background(Theme.border).padding(.leading, 82)
        }
    }

    // MARK: - TIDAL search helpers

    private func searchAndPlay(trackName: String, artistName: String) async {
        do {
            let api = MonochromeAPI()
            let results = try await api.searchTracks(query: "\(trackName) \(artistName)")
            if let first = results.first {
                await MainActor.run { audioPlayer.play(track: first) }
            }
        } catch {
            print("[Genre] Search failed: \(error.localizedDescription)")
        }
    }

    private func searchAndOpenAlbum(albumName: String, artistName: String) async {
        do {
            let api = MonochromeAPI()
            let results = try await api.searchAlbums(query: "\(albumName) \(artistName)")
            if let first = results.first {
                await MainActor.run { navigationPath.append(first) }
            }
        } catch {
            print("[Genre] Album search failed: \(error.localizedDescription)")
        }
    }

    private func searchAndOpenArtist(artistName: String) async {
        do {
            let api = MonochromeAPI()
            let (artists, _, _, _) = try await api.searchAll(query: artistName)
            if let first = artists.first {
                await MainActor.run { navigationPath.append(first) }
            }
        } catch {
            print("[Genre] Artist search failed: \(error.localizedDescription)")
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - ExploreTrackCard

struct ExploreTrackCard: View {
    let track: ExploreTrack
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(url: track.coverUrl) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Theme.card)
                            .overlay(Image(systemName: "music.note").foregroundColor(Theme.mutedForeground))
                    }
                }
                .frame(width: 130, height: 130)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.foreground)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)

                Text(track.artistName)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mutedForeground)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ExploreItemCard

struct ExploreItemCard: View {
    let title: String
    let subtitle: String
    let coverUrl: URL?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(url: coverUrl) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Theme.card)
                            .overlay(Image(systemName: "music.note").foregroundColor(Theme.mutedForeground))
                    }
                }
                .frame(width: 130, height: 130)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.foreground)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.mutedForeground)
                        .lineLimit(1)
                        .frame(width: 130, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
