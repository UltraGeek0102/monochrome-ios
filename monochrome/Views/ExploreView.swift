import SwiftUI
import Combine

// MARK: - API Models

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

struct ExploreGenre: Identifiable {
    let id: String
    let name: String
}

// MARK: - ViewModel

@MainActor
class ExploreViewModel: ObservableObject {
    @Published var trendingTracks: [ExploreTrack] = []
    @Published var trendingAlbums: [ExploreAlbum] = []
    @Published var featuredPlaylists: [ExplorePlaylist] = []
    @Published var extraSections: [ExploreSection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    let genres: [ExploreGenre] = [
        .init(id: "hip_hop",         name: "Hip-Hop"),
        .init(id: "rnb",             name: "R&B / Soul"),
        .init(id: "pop",             name: "Pop"),
        .init(id: "indierock",       name: "Rock / Indie"),
        .init(id: "dance_electronic",name: "Dance & Electronic"),
        .init(id: "jazz",            name: "Jazz"),
        .init(id: "classical",       name: "Classical"),
        .init(id: "metal",           name: "Metal"),
        .init(id: "latin",           name: "Latin"),
        .init(id: "reggae",          name: "Reggae"),
        .init(id: "country",         name: "Country"),
        .init(id: "blues",           name: "Blues"),
        .init(id: "kpop",            name: "K-Pop"),
        .init(id: "americana",       name: "Folk / Americana"),
        .init(id: "world",           name: "Global"),
        .init(id: "gospel",          name: "Gospel"),
        .init(id: "retro",           name: "Legacy"),
        .init(id: "kids",            name: "Kids"),
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
                errorMessage = "Explore unavailable (server error)"
                return
            }
            let decoded = try JSONDecoder().decode(ExploreResponse.self, from: data)
            trendingTracks   = decoded.top_tracks        ?? []
            trendingAlbums   = decoded.top_albums        ?? []
            featuredPlaylists = decoded.featured_playlists ?? []
            extraSections    = decoded.sections?.filter { ($0.items?.count ?? 0) > 0 } ?? []
        } catch {
            errorMessage = "Failed to load explore: \(error.localizedDescription)"
        }
    }
}

// MARK: - ExploreView

struct ExploreView: View {
    @Binding var navigationPath: CompatNavigationPath
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @StateObject private var vm = ExploreViewModel()

    var body: some View {
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
                    // Genres grid
                    genresSection

                    // Trending Tracks
                    if !vm.trendingTracks.isEmpty {
                        exploreSection(title: "Trending Tracks") {
                            ForEach(vm.trendingTracks.prefix(20)) { track in
                                ExploreTrackCard(track: track) {
                                    playTrack(id: track.id)
                                }
                            }
                        }
                    }

                    // Trending Albums
                    if !vm.trendingAlbums.isEmpty {
                        exploreSection(title: "Trending Albums") {
                            ForEach(vm.trendingAlbums.prefix(20)) { album in
                                ExploreItemCard(
                                    title: album.title,
                                    subtitle: album.artist?.name ?? "",
                                    coverUrl: album.coverUrl
                                ) { navigationPath.append(Album(id: album.id, title: album.title, cover: album.cover, numberOfTracks: nil, releaseDate: nil, artist: nil, type: nil)) }
                            }
                        }
                    }

                    // Featured Playlists
                    if !vm.featuredPlaylists.isEmpty {
                        exploreSection(title: "Featured Playlists") {
                            ForEach(vm.featuredPlaylists.prefix(20)) { pl in
                                ExploreItemCard(
                                    title: pl.title,
                                    subtitle: "Playlist",
                                    coverUrl: pl.coverUrl
                                ) { /* navigate to playlist */ }
                            }
                        }
                    }

                    // Extra sections from server
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
                                    ) { }
                                }
                            }
                        }
                    }

                    Color.clear.frame(height: 100)
                }
                .padding(.top, 16)
            }
        }
        .background(Theme.background)
        .task { await vm.load() }
    }

    // MARK: - Genres

    private var genresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genres")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.foreground)
                .padding(.horizontal, 16)

            let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(vm.genres) { genre in
                    Text(genre.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
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

// MARK: - ExploreItemCard (albums, playlists, etc)

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
