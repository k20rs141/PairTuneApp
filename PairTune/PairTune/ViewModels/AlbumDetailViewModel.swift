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
        if album.isPlaylist { self.kindLabel = "Playlist" }
    }

    init(playlist: Playlist, roomViewModel: RoomViewModel) {
        self.album = Album(
            id: playlist.id,
            title: playlist.title,
            artistName: playlist.curatorName,
            artworkURL: playlist.artworkURL,
            storefront: playlist.storefront,
            isPlaylist: true
        )
        self.roomViewModel = roomViewModel
        self.kindLabel = "Playlist"
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        loadTask?.cancel()
        loadTask = Task { [albumID = album.id, storefront = album.storefront, isPlaylist = album.isPlaylist] in
            do {
                let detail: AlbumDetail
                if isPlaylist {
                    detail = try await Self.fetchPlaylistDetail(playlistID: albumID, storefront: storefront)
                } else {
                    detail = try await Self.fetchAlbumDetail(albumID: albumID, storefront: storefront)
                }
                guard !Task.isCancelled else { return }
                self.tracks = detail.tracks
                self.totalDurationSeconds = detail.tracks.reduce(0) { $0 + $1.duration }
                self.releaseDate = detail.releaseDate
                self.kindLabel = isPlaylist ? "Playlist" : (detail.isSingle ? "Single" : (detail.isEP ? "EP" : "Album"))
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

    /// アルバム全曲を再生する。先頭曲を即時再生し、残りはキュー末尾に追加。
    /// Shared モードでは Realtime 経由で相手のキューにも同期される。
    func playAll() {
        guard let first = tracks.first else { return }
        Task {
            await roomViewModel.playAsHost(first)
            for track in tracks.dropFirst() {
                await roomViewModel.addToQueue(track)
            }
        }
    }

    /// 「次に再生」CTA(text.line.first.and.arrowtriangle.forward)から呼ぶ。
    /// アルバム/プレイリストの全曲を up-next 先頭に、トラック順を保ったまま挿入する。
    /// 再生はしない。
    func playNextAll() {
        guard !tracks.isEmpty else { return }
        Task {
            // playNextInQueue は常に「現先頭の前」に挿入するため、逆順で呼ぶと
            // 最終的にトラック順が保たれる。
            for track in tracks.reversed() {
                await roomViewModel.playNextInQueue(track)
            }
        }
    }

    /// トラックタップ時、キューが空ならタップした曲以降を up-next にまとめて追加する。
    /// Apple Music ライクな挙動(タップした曲が再生されつつ、残りはキューに積まれる)。
    func queueRemainingIfEmpty(after track: Track) {
        guard roomViewModel.queue.items.isEmpty else { return }
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let rest = Array(tracks.dropFirst(idx + 1))
        guard !rest.isEmpty else { return }
        Task {
            for t in rest {
                await roomViewModel.addToQueue(t)
            }
        }
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

    private static func fetchPlaylistDetail(playlistID: String, storefront explicit: String?) async throws -> AlbumDetail {
        let storefront = explicit ?? Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/playlists/\(playlistID)?l=ja-JP&include=tracks") else {
            return AlbumDetail(tracks: [], releaseDate: nil, isSingle: false, isEP: false, albumArtistId: nil)
        }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(PlaylistDetailResponse.self, from: resp.data)
        guard let resource = decoded.data?.first else {
            return AlbumDetail(tracks: [], releaseDate: nil, isSingle: false, isEP: false, albumArtistId: nil)
        }
        let trackResources = resource.relationships?.tracks?.data ?? []
        let tracks = trackResources.compactMap { $0.toTrack() }
        return AlbumDetail(
            tracks: tracks,
            releaseDate: resource.attributes?.lastModifiedDate,
            isSingle: false,
            isEP: false,
            albumArtistId: nil
        )
    }

    private static func fetchAlbumDetail(albumID: String, storefront explicit: String?) async throws -> AlbumDetail {
        // album.storefront を優先(検索 → Artist → Album 経由なら検索時の storefront、
        // それ以外は端末ロケール)。クロスストアフロントで 404 / 500 になる事象を回避。
        let storefront = explicit ?? Locale.current.region?.identifier.lowercased() ?? "jp"
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

// MARK: - Playlist detail response

private struct PlaylistDetailResponse: Decodable {
    let data: [PlaylistResource]?

    struct PlaylistResource: Decodable {
        let id: String
        let attributes: PlaylistAttributes?
        let relationships: PlaylistRelationships?
    }

    struct PlaylistAttributes: Decodable {
        let name: String
        let curatorName: String?
        let lastModifiedDate: String?
    }

    struct PlaylistRelationships: Decodable {
        let tracks: TracksRel?
    }

    struct TracksRel: Decodable {
        let data: [SongResource]?
    }

    struct SongResource: Decodable {
        let id: String
        let type: String?
        let attributes: SongAttributes?

        func toTrack() -> Track? {
            // music-videos など songs 以外はスキップ
            if let t = type, t != "songs" { return nil }
            guard let attrs = attributes else { return nil }
            let artworkURL = attrs.artwork.flatMap { art -> URL? in
                URL(string: art.url
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
                    .init(color: .pairtuneSecondary, location: 0.0),
                    .init(color: Color(hex: "2E0E2A"), location: 1.0),
                ],
                dominant: .pairtuneSecondary,
                artworkURL: artworkURL,
                albumId: nil,
                artistId: nil
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

    struct ArtworkInfo: Decodable {
        let url: String
    }
}
