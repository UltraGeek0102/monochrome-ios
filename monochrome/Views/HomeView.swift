import SwiftUI
import Combine
import Combine

// MARK: - Home ViewModel

@MainActor
class HomeViewModel: ObservableObject {
    @Published var editorsPicks: [EditorsPick] = []
    @Published var newAlbums: [AOTYAlbum] = []
    @Published var newSingles: [AOTYAlbum] = []
    @Published var recommendations: [Track] = []
    @Published var isLoadingPicks = false
    @Published var isLoadingNew = false
    @Published var isLoadingRecs = false

    private let api = MonochromeAPI()

    struct EditorsPick: Identifiable {
        let id: String
        let type: String        // "album" | "track" | "artist"
        let itemId: Int
        let title: String
        let subtitle: String
        let cover: String?
        var coverUrl: URL? {
            guard let c = cover else { return nil }
            if c.hasPrefix("http") { return URL(string: c) }
            let fmt = c.replacingOccurrences(of: "-", with: "/")
            return URL(string: "https://resources.tidal.com/images/\(fmt)/320x320.jpg")
        }
    }

    struct AOTYAlbum: Identifiable {
        let id = UUID()
        let title: String
        let artist: String
        let cover: String?
        let rating: String?
        let year: String?
        var coverUrl: URL? { cover.flatMap { URL(string: $0) } }
    }

    func loadAll(currentTrackId: Int?) async {
        async let picks: () = loadEditorsPicks()
        async let newRel: () = loadNewReleases()
        async let recs: () = loadRecommendations(seedTrackId: currentTrackId)
        _ = await (picks, newRel, recs)
    }

    func loadEditorsPicks() async {
        guard editorsPicks.isEmpty else { return }
        isLoadingPicks = true
        defer { isLoadingPicks = false }

        guard let url = URL(string: "https://monochrome.tf/editors-picks.json"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        editorsPicks = items.prefix(12).compactMap { item in
            guard let type = item["type"] as? String,
                  let id = item["id"] as? Int else { return nil }
            let title  = item["title"] as? String ?? ""
            let artist = (item["artist"] as? [String: Any])?["name"] as? String
                      ?? item["artist"] as? String ?? ""
            let cover  = item["cover"] as? String
            return EditorsPick(id: "\(type)_\(id)", type: type, itemId: id,
                               title: title, subtitle: artist, cover: cover)
        }
    }

    func loadNewReleases() async {
        guard newAlbums.isEmpty else { return }
        isLoadingNew = true
        defer { isLoadingNew = false }

        let aoty = "https://aoty.prigoana.pw"
        async let albumsReq = fetch("\(aoty)/discover")
        async let singlesReq = fetch("\(aoty)/discover/singles")

        newAlbums  = parseAOTY(await albumsReq)
        newSingles = parseAOTY(await singlesReq)
    }

    func loadRecommendations(seedTrackId: Int?) async {
        guard recommendations.isEmpty, let id = seedTrackId else { return }
        isLoadingRecs = true
        defer { isLoadingRecs = false }
        recommendations = (try? await api.fetchRecommendations(trackId: id)) ?? []
    }

    private func fetch(_ urlStr: String) async -> Data? {
        guard let url = URL(string: urlStr),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func parseAOTY(_ data: Data?) -> [AOTYAlbum] {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        let items: [[String: Any]]
        if let arr = json["albums"] as? [[String: Any]] { items = arr }
        else if let arr = json["singles"] as? [[String: Any]] { items = arr }
        else if let arr = json["data"] as? [[String: Any]] { items = arr }
        else { return [] }

        return items.prefix(15).compactMap { a in
            guard let title = a["name"] as? String ?? a["title"] as? String,
                  let artist = a["artist"] as? String
                            ?? (a["artist"] as? [String: Any])?["name"] as? String else { return nil }
            let cover  = a["image"] as? String ?? a["cover"] as? String
            let rating = a["rating"] as? String ?? (a["rating"] as? Int).map { "\($0)" }
            let year   = a["year"] as? String ?? (a["year"] as? Int).map { "\($0)" }
            return AOTYAlbum(title: title, artist: artist, cover: cover, rating: rating, year: year)
        }
    }
}

// MARK: - HomeView

struct HomeView: View {
    @Binding var navigationPath: CompatNavigationPath
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var profileManager: ProfileManager
    @StateObject private var vm = HomeViewModel()

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    private var userName: String? {
        let name = profileManager.profile.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name.components(separatedBy: " ").first
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Greeting
                greetingHeader
                    .padding(.bottom, 20)

                // Quick Play — recently played 2-col grid (keep from original)
                if !recentTracksList.isEmpty {
                    homeSection(title: "Recently Played", seeAllAction: nil) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(recentTracksList.prefix(6)) { track in
                                RecentTrackCard(track: track) { audioPlayer.play(track: track) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 28)
                }

                // Editor's Picks
                if !vm.editorsPicks.isEmpty || vm.isLoadingPicks {
                    homeSection(title: "Editor's Picks", seeAllAction: nil) {
                        horizontalScroll {
                            if vm.isLoadingPicks {
                                skeletonRow
                            } else {
                                ForEach(vm.editorsPicks) { pick in
                                    HomeCard(
                                        title: pick.title,
                                        subtitle: pick.subtitle,
                                        coverUrl: pick.coverUrl
                                    ) { navigateToPick(pick) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }

                // New Albums (AOTY)
                if !vm.newAlbums.isEmpty || vm.isLoadingNew {
                    homeSection(title: "New Releases", seeAllAction: nil) {
                        horizontalScroll {
                            if vm.isLoadingNew {
                                skeletonRow
                            } else {
                                ForEach(vm.newAlbums) { album in
                                    HomeCard(
                                        title: album.title,
                                        subtitle: album.artist,
                                        coverUrl: album.coverUrl,
                                        badge: album.year
                                    ) { searchAndOpenAlbum(name: album.title, artist: album.artist) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }

                // New Singles (AOTY)
                if !vm.newSingles.isEmpty {
                    homeSection(title: "New Singles & EPs", seeAllAction: nil) {
                        horizontalScroll {
                            ForEach(vm.newSingles) { single in
                                HomeCard(
                                    title: single.title,
                                    subtitle: single.artist,
                                    coverUrl: single.coverUrl
                                ) { searchAndOpenAlbum(name: single.title, artist: single.artist) }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }

                // Favorite Artists
                if !libraryManager.favoriteArtists.isEmpty {
                    homeSection(title: "Your Artists", seeAllAction: nil) {
                        horizontalScroll {
                            ForEach(libraryManager.favoriteArtists.prefix(15)) { artist in
                                ArtistPill(artist: artist) { navigationPath.append(artist) }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }

                // Favorite Albums
                if !libraryManager.favoriteAlbums.isEmpty {
                    homeSection(title: "Your Albums", seeAllAction: nil) {
                        horizontalScroll {
                            ForEach(libraryManager.favoriteAlbums.prefix(15)) { album in
                                HomeCard(
                                    title: album.title,
                                    subtitle: album.artist?.name ?? "",
                                    coverUrl: MonochromeAPI().getImageUrl(id: album.cover)
                                ) { navigationPath.append(album) }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }

                // Favorite Tracks
                if !libraryManager.favoriteTracks.isEmpty {
                    homeSection(title: "Your Favorites", seeAllAction: nil) {
                        VStack(spacing: 0) {
                            ForEach(Array(libraryManager.favoriteTracks.prefix(5).enumerated()), id: \.element.id) { index, track in
                                let queue    = Array(libraryManager.favoriteTracks.dropFirst(index + 1))
                                let previous = Array(libraryManager.favoriteTracks.prefix(index))
                                TrackRow(track: track, queue: queue, previousTracks: previous,
                                         showCover: true, navigationPath: $navigationPath)
                                if index < min(4, libraryManager.favoriteTracks.count - 1) {
                                    Divider().background(Theme.border).padding(.leading, 72)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 28)
                }

                // Recommended (based on current/last played track)
                if !vm.recommendations.isEmpty {
                    homeSection(title: "Recommended For You", seeAllAction: nil) {
                        horizontalScroll {
                            ForEach(vm.recommendations.prefix(15)) { track in
                                HomeCard(
                                    title: track.title,
                                    subtitle: track.artist?.name ?? "",
                                    coverUrl: MonochromeAPI().getImageUrl(id: track.album?.cover)
                                ) { audioPlayer.play(track: track) }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }

                // Empty state
                if recentTracksList.isEmpty && vm.editorsPicks.isEmpty && libraryManager.favoriteTracks.isEmpty && !vm.isLoadingPicks {
                    emptyState
                }

                Color.clear.frame(height: 100)
            }
            .padding(.top, 8)
        }
        .background(Theme.background)
        .task {
            let seedId = audioPlayer.currentTrack?.id ?? audioPlayer.playHistory.last?.id
            await vm.loadAll(currentTrackId: seedId)
        }
    }

    // MARK: - Greeting Header

    private var greetingHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting + (userName.map { ", \($0)" } ?? ""))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(Theme.foreground)
                Text(formattedDate)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.mutedForeground)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    // MARK: - Section Builder

    private func homeSection<Content: View>(title: String, seeAllAction: (() -> Void)?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.foreground)
                Spacer()
                if let action = seeAllAction {
                    Button("See All", action: action)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.mutedForeground)
                }
            }
            .padding(.horizontal, 16)
            content()
        }
    }

    private func horizontalScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { content() }
                .padding(.horizontal, 16)
        }
    }

    private var skeletonRow: some View {
        ForEach(0..<6, id: \.self) { _ in
            SkeletonPill(width: 130, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(Theme.mutedForeground.opacity(0.3))
            Text("Search for a track to get started")
                .font(.system(size: 16))
                .foregroundColor(Theme.mutedForeground)
            Text("Your recently played, favorites, and recommendations will appear here.")
                .font(.system(size: 13))
                .foregroundColor(Theme.mutedForeground.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Recently played dedup

    private var recentTracksList: [Track] {
        var tracks: [Track] = []
        if let current = audioPlayer.currentTrack { tracks.append(current) }
        for track in audioPlayer.playHistory.reversed() {
            if !tracks.contains(where: { $0.id == track.id }) { tracks.append(track) }
        }
        return tracks
    }

    // MARK: - Navigation helpers

    private func navigateToPick(_ pick: HomeViewModel.EditorsPick) {
        switch pick.type {
        case "album":
            Task {
                if let detail = try? await MonochromeAPI().fetchAlbum(id: pick.itemId) {
                    await MainActor.run { navigationPath.append(detail.album) }
                }
            }
        case "artist":
            Task {
                if let detail = try? await MonochromeAPI().fetchArtist(id: pick.itemId) {
                    let artist = Artist(id: detail.id, name: detail.name, picture: detail.picture, popularity: nil)
                    await MainActor.run { navigationPath.append(artist) }
                }
            }
        case "track":
            Task {
                if let track = try? await MonochromeAPI().fetchTrack(id: pick.itemId) {
                    await MainActor.run { audioPlayer.play(track: track) }
                }
            }
        default: break
        }
    }

    private func searchAndOpenAlbum(name: String, artist: String) {
        Task {
            if let album = try? await MonochromeAPI().searchAlbums(query: "\(name) \(artist)").first {
                await MainActor.run { navigationPath.append(album) }
            }
        }
    }
}

// MARK: - HomeCard (uniform card used throughout home)

struct HomeCard: View {
    let title: String
    let subtitle: String
    let coverUrl: URL?
    var badge: String? = nil
    let onTap: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    CachedAsyncImage(url: coverUrl) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Theme.secondary)
                                .overlay(Image(systemName: "music.note")
                                    .font(.system(size: 24))
                                    .foregroundColor(Theme.mutedForeground.opacity(0.4)))
                        }
                    }
                    .frame(width: 130, height: 130)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.foreground)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mutedForeground)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

// MARK: - ArtistPill

struct ArtistPill: View {
    let artist: Artist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                CachedAsyncImage(url: MonochromeAPI().getImageUrl(id: artist.picture, size: 160)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(Theme.secondary)
                            .overlay(Image(systemName: "person.fill")
                                .foregroundColor(Theme.mutedForeground.opacity(0.4)))
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))

                Text(artist.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.foreground)
                    .lineLimit(1)
                    .frame(width: 80)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - RecentTrackCard (unchanged from original)

struct RecentTrackCard: View {
    let track: Track
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                CachedAsyncImage(url: MonochromeAPI().getImageUrl(id: track.album?.cover)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Theme.card)
                    }
                }
                .frame(width: 56, height: 56)
                .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.foreground)
                        .lineLimit(1)
                    QualityBadge(tags: track.mediaMetadata?.tags)
                }
                .padding(.horizontal, 10)

                Spacer()
            }
            .frame(height: 56)
            .background(Theme.secondary.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CompatNavigationView {
        HomeView(navigationPath: .constant(CompatNavigationPath()))
    }
    .environmentObject(AudioPlayerService())
    .environmentObject(LibraryManager.shared)
    .environmentObject(DownloadManager.shared)
    .environmentObject(ProfileManager.shared)
}
