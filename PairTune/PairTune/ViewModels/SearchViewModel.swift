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
        guard !text.isEmpty else {
            songs = []
            artists = []
            isSearching = false
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
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(text)
        }
    }

    func selectSong(_ track: Track) {
        Task { await roomViewModel.playAsHost(track) }
    }

    private func search(_ query: String) async {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            isSearching = false
            return
        }
        let storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/search?term=\(encoded)&types=songs,artists&limit=20&l=ja-JP") else {
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
            searchError = "検索できません。リトライしてください"
        }
        isSearching = false
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
                artworkURL: artworkURL
            )
        }
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
