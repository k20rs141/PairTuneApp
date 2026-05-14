import Foundation
import MusicKit
import SwiftUI

@Observable
@MainActor
final class AlbumDetailViewModel {
    let album: Album
    var tracks: [Track] = []
    var totalDurationSeconds: Int = 0
    var releaseDate: String?
    var kindLabel: String = "Album"
    var isLoading: Bool = false
    var loadError: String?
    /// アルバム所有者の Apple Music Artist ID(`/albums/{id}?include=artists` で解決)。
    /// 「アーティスト名」タップ時に ArtistDetailView へ push するために露出する。
    var albumArtistId: String?

    private let roomViewModel: RoomViewModel
    private var loadTask: Task<Void, Never>?

    init(album: Album, roomViewModel: RoomViewModel) {
        self.album = album
        self.roomViewModel = roomViewModel
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        loadTask?.cancel()
        loadTask = Task { [albumID = album.id] in
            do {
                let detail = try await Self.fetchAlbumDetail(albumID: albumID)
                guard !Task.isCancelled else { return }
                self.tracks = detail.tracks
                self.totalDurationSeconds = detail.tracks.reduce(0) { $0 + $1.duration }
                self.releaseDate = detail.releaseDate
                self.kindLabel = detail.isSingle ? "Single" : (detail.isEP ? "EP" : "Album")
                self.albumArtistId = detail.albumArtistId
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                return
            } catch {
                print("[AlbumDetailViewModel] load error:", error)
                self.loadError = "読み込みできません。リトライしてください"
                self.isLoading = false
            }
        }
    }

    func playAll() {
        guard let first = tracks.first else { return }
        Task { await roomViewModel.playAsHost(first) }
    }

    func play(_ track: Track) {
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

    // MARK: - Apple Music API

    private struct AlbumDetail {
        let tracks: [Track]
        let releaseDate: String?
        let isSingle: Bool
        let isEP: Bool
        let albumArtistId: String?
    }

    private static func fetchAlbumDetail(albumID: String) async throws -> AlbumDetail {
        let storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/albums/\(albumID)?l=ja-JP&include=artists,tracks") else {
            return AlbumDetail(tracks: [], releaseDate: nil, isSingle: false, isEP: false, albumArtistId: nil)
        }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(AlbumResponse.self, from: resp.data)
        guard let resource = decoded.data?.first else {
            return AlbumDetail(tracks: [], releaseDate: nil, isSingle: false, isEP: false, albumArtistId: nil)
        }
        let attrs = resource.attributes
        let albumArtistId = resource.relationships?.artists?.data?.first?.id
        let trackResources = resource.relationships?.tracks?.data ?? []
        let tracks = trackResources.compactMap { $0.toTrack(
            albumID: albumID,
            albumArtistId: albumArtistId,
            albumArtworkFallback: attrs?.artwork
        ) }
        return AlbumDetail(
            tracks: tracks,
            releaseDate: attrs?.releaseDate,
            isSingle: attrs?.isSingle ?? false,
            isEP: (attrs?.trackCount ?? 0) <= 6 && (attrs?.trackCount ?? 0) > 1,
            albumArtistId: albumArtistId
        )
    }
}

// MARK: - Response types

private struct AlbumResponse: Decodable {
    let data: [AlbumResource]?

    struct AlbumResource: Decodable {
        let id: String
        let attributes: AlbumAttributes?
        let relationships: AlbumRelationships?
    }

    struct AlbumAttributes: Decodable {
        let name: String
        let artistName: String?
        let releaseDate: String?
        let trackCount: Int?
        let isSingle: Bool?
        let artwork: ArtworkInfo?
    }

    struct AlbumRelationships: Decodable {
        let tracks: TracksRel?
        let artists: ArtistsRel?
    }

    struct TracksRel: Decodable {
        let data: [TrackResource]?
    }

    struct ArtistsRel: Decodable {
        let data: [ArtistID]?
    }

    struct ArtistID: Decodable {
        let id: String
    }

    struct TrackResource: Decodable {
        let id: String
        let attributes: TrackAttributes?

        func toTrack(albumID: String, albumArtistId: String?, albumArtworkFallback: ArtworkInfo?) -> Track? {
            guard let attrs = attributes else { return nil }
            let art = attrs.artwork ?? albumArtworkFallback
            let artworkURL = art.flatMap { a -> URL? in
                URL(string: a.url
                    .replacingOccurrences(of: "{w}", with: "600")
                    .replacingOccurrences(of: "{h}", with: "600"))
            }
            return Track(
                id: id,
                title: attrs.name,
                artist: attrs.artistName,
                album: attrs.albumName ?? "",
                duration: (attrs.durationInMillis ?? 0) / 1000,
                gradientStops: [
                    .init(color: .pairtunePrimary, location: 0.0),
                    .init(color: Color(hex: "2E0E2A"), location: 1.0),
                ],
                dominant: .pairtunePrimary,
                artworkURL: artworkURL,
                albumId: albumID,
                artistId: albumArtistId
            )
        }
    }

    struct TrackAttributes: Decodable {
        let name: String
        let artistName: String
        let albumName: String?
        let durationInMillis: Int?
        let artwork: ArtworkInfo?
    }

    struct ArtworkInfo: Decodable {
        let url: String
    }
}
