import Foundation
import MusicKit
import SwiftUI

@Observable
@MainActor
final class ArtistDetailViewModel {
    let artist: Artist
    var topSongs: [Track] = []
    var albums: [Album] = []
    var singles: [Album] = []
    var liveAlbums: [Album] = []
    var featuredPlaylists: [Playlist] = []
    var isLoading: Bool = false
    var loadError: String?

    let roomViewModel: RoomViewModel
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
        loadTask = Task { [artistID = artist.id, storefront = artist.storefront] in
            // songs/albums は失敗時にエラー表示するためスロー。
            // singles/liveAlbums/playlists はオプショナルなのでエラーを吸収し空配列を返す。
            async let songsResult: [Track] = Self.fetchTopSongs(artistID: artistID, storefront: storefront)
            async let albumsResult: [Album] = Self.fetchAlbums(artistID: artistID, storefront: storefront)
            async let singlesResult: [Album] = Self.fetchSingles(artistID: artistID, storefront: storefront)
            async let liveResult: [Album] = Self.fetchLiveAlbums(artistID: artistID, storefront: storefront)
            async let playlistsResult: [Playlist] = Self.fetchFeaturedPlaylists(artistID: artistID, storefront: storefront)
            do {
                let (songs, albums) = try await (songsResult, albumsResult)
                guard !Task.isCancelled else { return }
                let singles = await singlesResult
                let live = await liveResult
                let playlists = await playlistsResult
                self.topSongs = songs
                self.albums = albums
                self.singles = singles
                self.liveAlbums = live
                self.featuredPlaylists = playlists
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                return
            } catch {
                print("[ArtistDetailViewModel] load error:", error)
                self.loadError = "読み込みできません。リトライしてください"
                self.isLoading = false
            }
        }
    }

    func selectSong(_ track: Track) {
        Task { await roomViewModel.playAsHost(track) }
    }

    /// トラックタップ時、キューが空なら topSongs のタップした曲以降を up-next にまとめて追加する。
    /// Apple Music ライクな挙動(タップした曲が再生されつつ、残りはキューに積まれる)。
    func queueRemainingTopSongsIfEmpty(after track: Track) {
        guard roomViewModel.queue.items.isEmpty else { return }
        guard let idx = topSongs.firstIndex(where: { $0.id == track.id }) else { return }
        let rest = Array(topSongs.dropFirst(idx + 1))
        guard !rest.isEmpty else { return }
        Task {
            for t in rest {
                await roomViewModel.addToQueue(t)
            }
        }
    }

    /// TrackContextMenu「お気に入りに追加」から呼ぶ。RoomViewModel に委譲。
    func addFavorite(_ track: Track) async {
        await roomViewModel.addFavoriteToCatalog(track)
    }

    /// TrackContextMenu「次に再生」から呼ぶ。現再生の直後にキュー挿入する。
    func playNext(_ track: Track) async {
        await roomViewModel.playNextInQueue(track)
    }

    /// Send-to-partner CTA。MVP では「トップソング先頭曲を再生する」=「相手に届ける」。
    /// playAsHost が shared モードでは relay/broadcast を行うため、相手の RoomView にも届く。
    func sendTopSongToPartner() {
        guard let first = topSongs.first else { return }
        Task { await roomViewModel.playAsHost(first) }
    }

    /// "Latest release" カード用。albums の先頭を最新リリースとして扱う(API 既定で release date desc)。
    var latestAlbum: Album? { albums.first }

    // MARK: - Apple Music API

    /// 検索由来の artist.storefront を優先し、未設定なら端末ロケールにフォールバック。
    private static func resolveStorefront(_ explicit: String?) -> String {
        explicit ?? Locale.current.region?.identifier.lowercased() ?? "jp"
    }

    private static func fetchTopSongs(artistID: String, storefront explicit: String?) async throws -> [Track] {
        let storefront = resolveStorefront(explicit)
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/view/top-songs?limit=20&l=ja-JP&include=albums,artists") else {
            return []
        }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(TopSongsResponse.self, from: resp.data)
        return decoded.data?.compactMap { $0.toTrack(fallbackArtistID: artistID, storefront: storefront) } ?? []
    }

    private static func fetchAlbums(artistID: String, storefront explicit: String?) async throws -> [Album] {
        let storefront = resolveStorefront(explicit)
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/albums?limit=20&l=ja-JP") else {
            return []
        }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(AlbumsResponse.self, from: resp.data)
        return decoded.data?.compactMap { $0.toAlbum(storefront: storefront) } ?? []
    }

    /// view/singles — 失敗時は空配列を返しエラーを伝搬しない(セクションを非表示にするだけ)。
    private static func fetchSingles(artistID: String, storefront explicit: String?) async -> [Album] {
        let storefront = resolveStorefront(explicit)
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/view/singles?limit=20&l=ja-JP") else {
            return []
        }
        do {
            let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            try Task.checkCancellation()
            let decoded = try JSONDecoder().decode(AlbumsResponse.self, from: resp.data)
            return decoded.data?.compactMap { $0.toAlbum(storefront: storefront) } ?? []
        } catch is CancellationError {
            return []
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return []
        } catch {
            print("[ArtistDetailViewModel] fetchSingles error (ignored):", error.localizedDescription)
            return []
        }
    }

    /// view/live-albums — 失敗時は空配列を返す。
    private static func fetchLiveAlbums(artistID: String, storefront explicit: String?) async -> [Album] {
        let storefront = resolveStorefront(explicit)
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/view/live-albums?limit=20&l=ja-JP") else {
            return []
        }
        do {
            let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            try Task.checkCancellation()
            let decoded = try JSONDecoder().decode(AlbumsResponse.self, from: resp.data)
            return decoded.data?.compactMap { $0.toAlbum(storefront: storefront) } ?? []
        } catch is CancellationError {
            return []
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return []
        } catch {
            print("[ArtistDetailViewModel] fetchLiveAlbums error (ignored):", error.localizedDescription)
            return []
        }
    }

    /// view/featured-playlists — 失敗時は空配列を返す。
    private static func fetchFeaturedPlaylists(artistID: String, storefront explicit: String?) async -> [Playlist] {
        let storefront = resolveStorefront(explicit)
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/view/featured-playlists?limit=20&l=ja-JP") else {
            return []
        }
        do {
            let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            try Task.checkCancellation()
            let decoded = try JSONDecoder().decode(FeaturedPlaylistsResponse.self, from: resp.data)
            return decoded.data?.compactMap { $0.toPlaylist(storefront: storefront) } ?? []
        } catch is CancellationError {
            return []
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return []
        } catch {
            print("[ArtistDetailViewModel] fetchFeaturedPlaylists error (ignored):", error.localizedDescription)
            return []
        }
    }
}

// MARK: - Apple Music response types

private struct TopSongsResponse: Decodable {
    let data: [SongResource]?

    struct SongResource: Decodable {
        let id: String
        let attributes: SongAttributes?
        let relationships: SongRelationships?

        func toTrack(fallbackArtistID: String, storefront: String) -> Track? {
            guard let attrs = attributes else { return nil }
            _ = storefront // 現状 Track には storefront を持たせていないため未使用。
                           // 将来 Track 自体にも storefront を埋め込みたくなったらここを使う。
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
                    .init(color: .pairtuneCoral, location: 0.0),
                    .init(color: Color(hex: "4A1D3D"), location: 1.0),
                ],
                dominant: .pairtuneCoral,
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
    struct RelRef: Decodable {
        let data: [RelID]?
    }
    struct RelID: Decodable {
        let id: String
    }
}

private struct AlbumsResponse: Decodable {
    let data: [AlbumResource]?

    struct AlbumResource: Decodable {
        let id: String
        let attributes: AlbumAttributes?

        func toAlbum(storefront: String) -> Album? {
            guard let attrs = attributes else { return nil }
            let artworkURL = attrs.artwork.flatMap { art -> URL? in
                let urlStr = art.url
                    .replacingOccurrences(of: "{w}", with: "300")
                    .replacingOccurrences(of: "{h}", with: "300")
                return URL(string: urlStr)
            }
            return Album(
                id: id,
                title: attrs.name,
                artistName: attrs.artistName,
                artworkURL: artworkURL,
                storefront: storefront
            )
        }
    }

    struct AlbumAttributes: Decodable {
        let name: String
        let artistName: String
        let artwork: ArtworkInfo?
    }
}

private struct ArtworkInfo: Decodable {
    let url: String
}

// MARK: - Featured playlists response

private struct FeaturedPlaylistsResponse: Decodable {
    let data: [PlaylistResource]?

    struct PlaylistResource: Decodable {
        let id: String
        let attributes: PlaylistAttributes?

        func toPlaylist(storefront: String) -> Playlist? {
            guard let attrs = attributes else { return nil }
            let artworkURL = attrs.artwork.flatMap { art -> URL? in
                URL(string: art.url
                    .replacingOccurrences(of: "{w}", with: "300")
                    .replacingOccurrences(of: "{h}", with: "300"))
            }
            return Playlist(
                id: id,
                title: attrs.name,
                curatorName: attrs.curatorName ?? "",
                artworkURL: artworkURL,
                storefront: storefront
            )
        }
    }

    struct PlaylistAttributes: Decodable {
        let name: String
        let curatorName: String?
        let artwork: ArtworkInfo?
    }
}
