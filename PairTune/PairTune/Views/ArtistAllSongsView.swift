import SwiftUI
import MusicKit

// MARK: - ArtistAllSongsView
//
// ArtistDetailView の「トップソング」セクションヘッダのタップ(More)で push する画面。
// `/v1/catalog/{sf}/artists/{id}/songs?limit=100&l=ja-JP&include=albums,artists` で
// アーティストの全曲を取得して縦リスト表示する。

@Observable
@MainActor
final class ArtistAllSongsViewModel {
    let artist: Artist
    var songs: [Track] = []
    var isLoading: Bool = false
    var loadError: String?

    private let roomViewModel: RoomViewModel
    private var loadTask: Task<Void, Never>?

    init(artist: Artist, roomViewModel: RoomViewModel) {
        self.artist = artist
        self.roomViewModel = roomViewModel
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        loadTask?.cancel()
        loadTask = Task { [artistID = artist.id] in
            do {
                let fetched = try await Self.fetchAllSongs(artistID: artistID)
                guard !Task.isCancelled else { return }
                songs = fetched
                isLoading = false
            } catch is CancellationError {
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                return
            } catch {
                print("[ArtistAllSongsViewModel] load error:", error)
                loadError = "読み込みできません。リトライしてください"
                isLoading = false
            }
        }
    }

    func selectSong(_ track: Track) {
        Task { await roomViewModel.playAsHost(track) }
    }

    func playNext(_ track: Track) async {
        await roomViewModel.playNextInQueue(track)
    }

    func addFavorite(_ track: Track) async {
        await roomViewModel.addFavoriteToCatalog(track)
    }

    private static func fetchAllSongs(artistID: String) async throws -> [Track] {
        let storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/songs?limit=100&l=ja-JP&include=albums,artists") else {
            return []
        }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(SongsResponse.self, from: resp.data)
        return decoded.data?.compactMap { $0.toTrack(fallbackArtistID: artistID) } ?? []
    }
}

// MARK: - View

struct ArtistAllSongsView: View {
    @State var viewModel: ArtistAllSongsViewModel
    var partnerName: String? = nil
    var onSelectTrack: (Track) -> Void
    var onSelectAlbum: ((Album) -> Void)? = nil

    @State private var contextTrack: Track?

    var body: some View {
        ZStack {
            Color.pairtuneSurface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.isLoading && viewModel.songs.isEmpty {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.pairtuneTextSecondary)
                            .padding(.top, 60)
                    } else if let err = viewModel.loadError, viewModel.songs.isEmpty {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.pairtuneSyncBad)
                            .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.songs) { track in
                                Button {
                                    onSelectTrack(track)
                                } label: {
                                    AllSongsRow(track: track, onMenu: { contextTrack = track })
                                }
                                .buttonStyle(.plain)
                                .highPriorityGesture(
                                    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                                        contextTrack = track
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 8)

                        Text("\(viewModel.songs.count) 曲")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "5A5566"))
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                    }
                }
            }
            .scrollIndicators(.hidden)

            if let track = contextTrack {
                TrackContextMenu(
                    track: track,
                    partnerName: partnerName,
                    onClose: { contextTrack = nil },
                    onFavorite: {
                        Task { await viewModel.addFavorite(track) }
                    },
                    onSendToPartner: { viewModel.selectSong(track) },
                    onPlayNext: { Task { await viewModel.playNext(track) } },
                    onShowAlbum: (onSelectAlbum != nil && track.albumId != nil) ? {
                        onSelectAlbum?(Album(
                            id: track.albumId!,
                            title: track.album,
                            artistName: track.artist,
                            artworkURL: track.artworkURL
                        ))
                    } : nil
                )
                .transition(.opacity)
            }
        }
        .navigationTitle("\(viewModel.artist.name) · 全曲")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.pairtuneSurface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if viewModel.songs.isEmpty { viewModel.load() }
        }
    }
}

// MARK: - Row

private struct AllSongsRow: View {
    let track: Track
    var onMenu: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = track.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            LinearGradient(stops: track.gradientStops, startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                } else {
                    LinearGradient(stops: track.gradientStops, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(track.album)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "7A7588"))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(fmt(track.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: "5A5566"))
                .monospacedDigit()
            Button(action: onMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "5A5566"))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 0.5)
                .padding(.leading, 74)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Response types

private struct SongsResponse: Decodable {
    let data: [SongResource]?

    struct SongResource: Decodable {
        let id: String
        let attributes: SongAttributes?
        let relationships: SongRelationships?

        func toTrack(fallbackArtistID: String) -> Track? {
            guard let attrs = attributes else { return nil }
            let artworkURL = attrs.artwork.flatMap { art -> URL? in
                let urlStr = art.url
                    .replacingOccurrences(of: "{w}", with: "300")
                    .replacingOccurrences(of: "{h}", with: "300")
                return URL(string: urlStr)
            }
            return Track(
                id: id,
                title: attrs.name,
                artist: attrs.artistName,
                album: attrs.albumName ?? "",
                duration: (attrs.durationInMillis ?? 0) / 1000,
                gradientStops: [
                    .init(color: .pairtunePrimary, location: 0.0),
                    .init(color: Color(hex: "4A1D3D"), location: 1.0),
                ],
                dominant: .pairtunePrimary,
                artworkURL: artworkURL,
                albumId: relationships?.albums?.data?.first?.id,
                artistId: relationships?.artists?.data?.first?.id ?? fallbackArtistID
            )
        }
    }

    struct SongAttributes: Decodable {
        let name: String
        let artistName: String
        let albumName: String?
        let durationInMillis: Int?
        let artwork: ArtworkInfo?
    }

    struct SongRelationships: Decodable {
        let albums: RelRef?
        let artists: RelRef?
    }
    struct RelRef: Decodable { let data: [RelID]? }
    struct RelID: Decodable { let id: String }
    struct ArtworkInfo: Decodable { let url: String }
}
