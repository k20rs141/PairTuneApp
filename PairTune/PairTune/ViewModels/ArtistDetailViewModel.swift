import Foundation
import MusicKit
import SwiftUI

@Observable
@MainActor
final class ArtistDetailViewModel {
    let artist: Artist
    var topSongs: [Track] = []
    var albums: [Album] = []
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
            async let songsResult: [Track] = Self.fetchTopSongs(artistID: artistID)
            async let albumsResult: [Album] = Self.fetchAlbums(artistID: artistID)
            do {
                let (songs, albums) = try await (songsResult, albumsResult)
                guard !Task.isCancelled else { return }
                self.topSongs = songs
                self.albums = albums
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

    private static func fetchTopSongs(artistID: String) async throws -> [Track] {
        let storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/view/top-songs?limit=20&l=ja-JP&include=albums,artists") else {
            return []
        }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(TopSongsResponse.self, from: resp.data)
        return decoded.data?.compactMap { $0.toTrack(fallbackArtistID: artistID) } ?? []
    }

    private static func fetchAlbums(artistID: String) async throws -> [Album] {
        let storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/albums?limit=20&l=ja-JP") else {
            return []
        }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(AlbumsResponse.self, from: resp.data)
        return decoded.data?.compactMap { $0.toAlbum() } ?? []
    }
}

// MARK: - Apple Music response types

private struct TopSongsResponse: Decodable {
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

        func toAlbum() -> Album? {
            guard let attrs = attributes else { return nil }
            let artworkURL = attrs.artwork.flatMap { art -> URL? in
                let urlStr = art.url
                    .replacingOccurrences(of: "{w}", with: "300")
                    .replacingOccurrences(of: "{h}", with: "300")
                return URL(string: urlStr)
            }
            return Album(id: id, title: attrs.name, artistName: attrs.artistName, artworkURL: artworkURL)
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
