import SwiftUI

// MARK: - API Models

struct HotTrack: Identifiable, Decodable {
    let id: Int
    let title: String
    let artist: String
    let cover: String?
    let rank: Int?
}

struct HotGenre: Identifiable, Decodable {
    let id: String
    let name: String
    let tracks: [HotTrack]
}

struct MixItem: Identifiable, Decodable {
    let id: String
    let title: String?
    let images: [MixImage]?

    struct MixImage: Decodable {
        let url: String?
        let width: Int?
        let height: Int?
    }

    var coverUrl: URL? {
        guard let urlStr = images?.first(where: { ($0.width ?? 0) >= 480 })?.url
                        ?? images?.first?.url else { return nil }
        return URL(string: urlStr)
    }
}

// MARK: - ViewModel

@MainActor
class ExploreViewModel: ObservableObject {
    @Published var genres: [HotGenre] = []
    @Published var mixes: [MixItem] = []
    @Published var isLoadingExplore = false
    @Published var isLoadingMixes = false
    @Published var errorMessage: String?

    private let api = MonochromeAPI()

    func loadExplore() async {
        guard genres.isEmpty else { return }
        isLoadingExplore = true
        errorMessage = nil
        defer { isLoadingExplore = false }

        do {
            let url = URL(string: "https://hot.monochrome.tf/")!
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                errorMessage = "Failed to load explore content"
                return
            }

            // Response is { genre_id: { name, tracks: [...] } }
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let genreOrder = ["hip_hop","rnb","dance_electronic","pop","rock","metal",
                              "classical","jazz","country","blues","folk","latin","reggae"]

            var result: [HotGenre] = []
            for key in genreOrder {
                guard let dict = raw[key] as? [String: Any],
                      let name = dict["name"] as? String,
                      let tracksArr = dict["tracks"] as? [[String: Any]] else { continue }

                let tracks: [HotTrack] = tracksArr.prefix(20).compactMap { t in
                    guard let id = t["id"] as? Int, let title = t["title"] as? String else { return nil }
                    return HotTrack(
                        id: id,
                        title: title,
                        artist: t["artist"] as? String ?? "",
                        cover: t["cover"] as? String,
                        rank: t["rank"] as? Int
                    )
                }
                result.append(HotGenre(id: key, name: name, tracks: tracks))
            }

            // Append any genres not in the ordered list
            for (key, value) in raw {
                guard !genreOrder.contains(key),
                      let dict = value as? [String: Any],
                      let name = dict["name"] as? String,
                      let tracksArr = dict["tracks"] as? [[String: Any]] else { continue }
                let tracks: [HotTrack] = tracksArr.prefix(20).compactMap { t in
                    guard let id = t["id"] as? Int, let title = t["title"] as? String else { return nil }
                    return HotTrack(id: id, title: title, artist: t["artist"] as? String ?? "",
                                   cover: t["cover"] as? String, rank: t["rank"] as? Int)
                }
                result.append(HotGenre(id: key, name: name, tracks: tracks))
            }

            genres = result
        } catch {
            errorMessage = "Failed to load explore: \(error.localizedDescription)"
        }
    }

    func loadMixes(artistId: Int? = nil) async {
        guard mixes.isEmpty else { return }
        isLoadingMixes = true
        defer { isLoadingMixes = false }

        // Fetch a handful of featured mix IDs from TIDAL via the API
        // Mixes are fetched per-track or per-artist via /mix/?id=
        // For the explore tab we use a set of known featured TIDAL mix IDs
        let featuredMixIds = [
            "000ec0b0dce2a866602c44e8cce25d",
            "000ec0b0dce2a866602c44e8cce25e",
            "0009e2080083e8ab7aeae76a43c8b0"
        ]

        var results: [MixItem] = []
        for mixId in featuredMixIds {
            if let mix = try? await api.fetchMix(id: mixId) {
                results.append(mix)
            }
        }
        mixes = results
    }

    func playTrack(id: Int, audioPlayer: AudioPlayerService) {
        Task {
            if let url = await api.fetchStreamUrlWithFallback(trackId: id, preferredQuality: .high) {
                // Build a minimal Track for playback
                if let track = try? await api.fetchTrack(id: id) {
                    await MainActor.run { audioPlayer.play(track: track) }
                }
            }
        }
    }
}

// MARK: - ExploreView

struct ExploreView: View {
    @Binding var navigationPath: CompatNavigationPath
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @StateObject private var vm = ExploreViewModel()
    @State private var selectedTab: ExploreTab = .hotNew

    enum ExploreTab: String, CaseIterable {
        case hotNew = "Hot & New"
        case mixes  = "Mixes"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            HStack(spacing: 0) {
                ForEach(ExploreTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                    } label: {
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
                                Rectangle()
                                    .fill(Theme.foreground)
                                    .frame(height: 2)
                            }
                        }
                    )
                }
            }
            .background(Theme.background)
            .overlay(Divider().background(Theme.secondary), alignment: .bottom)

            if selectedTab == .hotNew {
                hotNewContent
            } else {
                mixesContent
            }
        }
        .background(Theme.background)
        .task { await vm.loadExplore() }
    }

    // MARK: Hot & New

    private var hotNewContent: some View {
        ScrollView {
            if vm.isLoadingExplore {
                skeletonGrid
            } else if let error = vm.errorMessage {
                Text(error)
                    .foregroundColor(Theme.mutedForeground)
                    .font(.system(size: 14))
                    .padding(40)
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(vm.genres) { genre in
                        genreSection(genre)
                    }
                    Color.clear.frame(height: 100)
                }
                .padding(.top, 16)
            }
        }
    }

    private func genreSection(_ genre: HotGenre) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(genre.name)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.foreground)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(genre.tracks) { track in
                        HotTrackCard(track: track, api: MonochromeAPI()) {
                            vm.playTrack(id: track.id, audioPlayer: audioPlayer)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonView()
                        .frame(width: 120, height: 16)
                        .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(0..<6, id: \.self) { _ in
                                SkeletonView()
                                    .frame(width: 130, height: 170)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    // MARK: Mixes

    private var mixesContent: some View {
        ScrollView {
            if vm.isLoadingMixes {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonView()
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
            } else if vm.mixes.isEmpty {
                Text("No mixes available")
                    .foregroundColor(Theme.mutedForeground)
                    .font(.system(size: 14))
                    .padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(vm.mixes) { mix in
                        MixCard(mix: mix, navigationPath: $navigationPath)
                    }
                }
                .padding(16)
            }
            Color.clear.frame(height: 100)
        }
        .task { await vm.loadMixes() }
    }
}

// MARK: - HotTrackCard

struct HotTrackCard: View {
    let track: HotTrack
    let api: MonochromeAPI
    let onTap: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    CachedAsyncImage(url: coverUrl) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Theme.card)
                                .overlay(Image(systemName: "music.note")
                                    .foregroundColor(Theme.mutedForeground.opacity(0.4)))
                        }
                    }
                    .frame(width: 130, height: 130)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if let rank = track.rank {
                        Text("#\(rank)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }

                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.foreground)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)

                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mutedForeground)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isPressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { _ in isPressed = false }
        )
    }

    private var coverUrl: URL? {
        guard let cover = track.cover else { return nil }
        let formatted = cover.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(formatted)/320x320.jpg")
    }
}

// MARK: - MixCard

struct MixCard: View {
    let mix: MixItem
    @Binding var navigationPath: CompatNavigationPath

    var body: some View {
        Button {
            navigationPath.append(NavigationDestination.mix(mix.id))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CachedAsyncImage(url: mix.coverUrl) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Theme.card)
                            .overlay(Image(systemName: "music.note.list")
                                .foregroundColor(Theme.mutedForeground.opacity(0.4)))
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let title = mix.title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.foreground)
                        .lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
