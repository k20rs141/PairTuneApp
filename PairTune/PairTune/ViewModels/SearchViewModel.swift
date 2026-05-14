import Foundation
import MusicKit
import SwiftUI

@Observable
@MainActor
final class SearchViewModel {
    var songs: [Track] = []
    var artists: [Artist] = []
    var isSearching: Bool = false
    var searchError: String?
    var subscriptionMissing: Bool = false
    /// `URLError.notConnectedToInternet` 等が検出された時に true。
    /// EmptyStateView を `.offline` で表示するためのフラグ。
    var isOffline: Bool = false
    /// 直近の検索クエリ。「再試行」CTA から検索をやり直す時に使う。
    private(set) var lastQuery: String = ""

    let roomViewModel: RoomViewModel
    private var debounceTask: Task<Void, Never>?

    init(roomViewModel: RoomViewModel) {
        self.roomViewModel = roomViewModel
        Task { await checkSubscription() }
    }

    /// Apple Music 契約状態を確認。未契約なら searchError + subscriptionMissing を立てる。
    func checkSubscription() async {
        do {
            let sub = try await MusicSubscription.current
            if !sub.canPlayCatalogContent {
                subscriptionMissing = true
                searchError = "Apple Music の契約が必要です"
            }
        } catch {
            print("[SearchViewModel] subscription check error:", error)
        }
    }

    func onSearchTextChanged(_ text: String) {
        debounceTask?.cancel()
        lastQuery = text
        guard !text.isEmpty else {
            songs = []
            artists = []
            isSearching = false
            isOffline = false
            searchError = subscriptionMissing ? "Apple Music の契約が必要です" : nil
            return
        }
        if subscriptionMissing {
            searchError = "Apple Music の契約が必要です"
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil
        isOffline = false
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(text)
        }
    }

    /// EmptyStateView の「再試行」CTA から呼ぶ。直近のクエリで再検索する。
    func retrySearch() {
        guard !lastQuery.isEmpty else { return }
        onSearchTextChanged(lastQuery)
    }

    func selectSong(_ track: Track) {
        Task { await roomViewModel.playAsHost(track) }
    }

    /// Search 経由のお気に入り追加。RoomViewModel.addFavoriteToCatalog に委譲。
    func addFavorite(_ track: Track) async {
        await roomViewModel.addFavoriteToCatalog(track)
    }

    /// TrackContextMenu「次に再生」から呼ぶ。現再生の直後にキュー挿入する。
    func playNext(_ track: Track) async {
        await roomViewModel.playNextInQueue(track)
    }

    private func search(_ query: String) async {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            isSearching = false
            return
        }
        let storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/search?term=\(encoded)&types=songs,artists&limit=20&l=ja-JP&include[songs]=albums,artists") else {
            isSearching = false
            return
        }
        do {
            let dataResponse = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            try Task.checkCancellation()
            let decoded = try JSONDecoder().decode(AppleMusicSearchResponse.self, from: dataResponse.data)
            songs = decoded.results.songs?.data.compactMap { $0.toTrack() } ?? []
            artists = decoded.results.artists?.data.compactMap { $0.toArtist() } ?? []
            searchError = nil
        } catch is CancellationError {
            return
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return
        } catch {
            print("[SearchViewModel] search error:", error)
            songs = []
            artists = []
            if let urlErr = error as? URLError, isOfflineCode(urlErr.code) {
                isOffline = true
                searchError = nil
            } else {
                isOffline = false
                searchError = "検索できません。リトライしてください"
            }
        }
        isSearching = false
    }

    private func isOfflineCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .timedOut:
            return true
        default:
            return false
        }
    }
}

// MARK: - Apple Music API response types

private struct AppleMusicSearchResponse: Decodable {
    let results: Results

    struct Results: Decodable {
        let songs: Songs?
        let artists: Artists?
    }

    struct Songs: Decodable {
        let data: [SongResource]
    }

    struct Artists: Decodable {
        let data: [ArtistResource]
    }

    struct SongResource: Decodable {
        let id: String
        let attributes: SongAttributes?
        let relationships: SongRelationships?

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
                    .init(color: .pairtuneCoral, location: 0.0),
                    .init(color: Color(hex: "4A1D3D"), location: 1.0),
                ],
                dominant: .pairtuneCoral,
                artworkURL: artworkURL,
                albumId: relationships?.albums?.data?.first?.id,
                artistId: relationships?.artists?.data?.first?.id
            )
        }
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

    struct ArtistResource: Decodable {
        let id: String
        let attributes: ArtistAttributes?

        func toArtist() -> Artist? {
            guard let attrs = attributes else { return nil }
            let artworkURL = attrs.artwork.flatMap { art -> URL? in
                let urlStr = art.url
                    .replacingOccurrences(of: "{w}", with: "300")
                    .replacingOccurrences(of: "{h}", with: "300")
                return URL(string: urlStr)
            }
            return Artist(id: id, name: attrs.name, artworkURL: artworkURL)
        }
    }

    struct SongAttributes: Decodable {
        let name: String
        let artistName: String
        let albumName: String?
        let durationInMillis: Int?
        let artwork: ArtworkInfo?
    }

    struct ArtistAttributes: Decodable {
        let name: String
        let artwork: ArtworkInfo?
    }

    struct ArtworkInfo: Decodable {
        let url: String
    }
}
