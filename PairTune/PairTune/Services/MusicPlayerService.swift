import Foundation
import MusicKit
import SwiftUI

@Observable
@MainActor
final class MusicPlayerService {
    var currentSong: Song?
    var playbackStatus: MusicPlayer.PlaybackStatus = .stopped
    var currentPlaybackTime: TimeInterval = 0

    var isPlaying: Bool { playbackStatus == .playing }

    private let player = ApplicationMusicPlayer.shared
    private var pollTask: Task<Void, Never>?

    // MARK: - Localized metadata

    /// 指定 songId を Apple Music API に `l=ja-JP` で問い合わせて Track を返す。
    /// MusicKit の `MusicCatalogResourceRequest` は locale 指定 API が無く、storefront 既定の
    /// メタデータを返すため、検索結果と表示が一致しない(日本語で検索したのに RoomView で
    /// 英語表示される)現象を回避する目的。
    /// 失敗時は nil を返し、呼び元は MusicKit 取得済みの song から fallback すれば良い。
    func fetchLocalizedTrack(songId: String) async -> Track? {
        let storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/songs/\(songId)?l=ja-JP") else {
            return nil
        }
        do {
            let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            let decoded = try JSONDecoder().decode(SongLookupResponse.self, from: resp.data)
            return decoded.data?.first?.toTrack()
        } catch {
            print("[MusicPlayerService] fetchLocalizedTrack error:", error)
            return nil
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let status = await MusicAuthorization.request()
        return status == .authorized
    }

    // MARK: - Playback

    /// Apple Music カタログ検索して最初にヒットした曲の ID を返す。
    func searchSongId(title: String, artist: String) async throws -> String? {
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
        request.limit = 1
        let response = try await request.response()
        return response.songs.first?.id.rawValue
    }

    /// 指定 songId の曲を time 秒から再生する。5秒以内に開始できなければタイムアウト。
    func load(songId: String, at time: TimeInterval = 0) async throws {
        try await withTimeout(seconds: 5) { [self] in
            let request = MusicCatalogResourceRequest<Song>(
                matching: \.id, equalTo: MusicItemID(rawValue: songId)
            )
            let response = try await request.response()
            guard let song = response.items.first else {
                throw MusicLoadError.notFound
            }
            currentSong = song
            player.queue = [song]
            try await player.play()
            if time > 0.5 {
                player.playbackTime = time
            }
            startPolling()
        }
    }

    func play() async throws {
        try await player.play()
        startPolling()
    }

    func pause() {
        player.pause()
    }

    func seek(to time: TimeInterval) {
        player.playbackTime = time
        currentPlaybackTime = time
    }

    func currentTime() -> TimeInterval {
        player.playbackTime
    }

    func stop() {
        player.stop()
        pollTask?.cancel()
        pollTask = nil
        currentSong = nil
        currentPlaybackTime = 0
        playbackStatus = .stopped
    }

    // MARK: - Private

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                currentPlaybackTime = player.playbackTime
                playbackStatus = player.state.playbackStatus
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

// MARK: - Errors

enum MusicLoadError: Error {
    case notFound
    case timeout
}

/// `body` を seconds 以内で完了させる。超過したら timeout を throw する。
@MainActor
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    body: @escaping @MainActor () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MusicLoadError.timeout
        }
        guard let result = try await group.next() else {
            throw MusicLoadError.timeout
        }
        group.cancelAll()
        return result
    }
}

// MARK: - Apple Music API decoding for fetchLocalizedTrack

private struct SongLookupResponse: Decodable {
    let data: [SongResource]?

    struct SongResource: Decodable {
        let id: String
        let attributes: SongAttributes?

        func toTrack() -> Track? {
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
                artworkURL: artworkURL
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

// MARK: - Song → Track mapping

extension Track {
    /// 既存 Track の表示メタデータ(title/artist/album/artworkURL/gradient)を保持しつつ、
    /// duration のみ MusicKit の Song から取得して新しい Track を返す。
    /// album が空だった場合のみ Song.albumTitle を採用する。
    /// artworkURL が nil だった場合のみ Song.artwork から補う。
    func applyingDuration(from song: Song) -> Track {
        Track(
            id: id,
            title: title,
            artist: artist,
            album: album.isEmpty ? (song.albumTitle ?? "") : album,
            duration: Int(song.duration ?? Double(duration)),
            gradientStops: gradientStops,
            dominant: dominant,
            artworkURL: artworkURL ?? song.artwork?.url(width: 300, height: 300)
        )
    }
}

extension Song {
    func toTrack() -> Track {
        Track(
            id: id.rawValue,
            title: title,
            artist: artistName,
            album: albumTitle ?? "",
            duration: Int(duration ?? 0),
            gradientStops: [
                .init(color: .pairtuneCoral, location: 0.0),
                .init(color: Color(hex: "4A1D3D"), location: 1.0),
            ],
            dominant: .pairtuneCoral,
            artworkURL: artwork?.url(width: 300, height: 300)
        )
    }
}
