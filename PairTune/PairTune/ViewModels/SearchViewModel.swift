import Foundation
import MusicKit
import SwiftUI
import Supabase

@Observable
@MainActor
final class SearchViewModel: Identifiable {
    /// `.sheet(item:)` 駆動用。インスタンスごとにユニーク。
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    var songs: [Track] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var isSearching: Bool = false
    var searchError: String?
    var subscriptionMissing: Bool = false
    /// `URLError.notConnectedToInternet` 等が検出された時に true。
    /// EmptyStateView を `.offline` で表示するためのフラグ。
    var isOffline: Bool = false
    /// 直近の検索クエリ。「再試行」CTA から検索をやり直す時に使う。
    private(set) var lastQuery: String = ""

    // MARK: - Empty state (検索前画面 §2.6.1)

    /// 検索履歴(UserDefaults 永続)。新しい順、最大 8 件。
    var recentSearches: [String] = []
    /// 自分の最近の再生(my_room_play_history)。
    var myRecentTracks: [PlayHistoryEntry] = []
    /// ふたりで最近の再生(shared_room_play_history)。Solo モードでは空。
    var sharedRecentTracks: [PlayHistoryEntry] = []
    /// 履歴から導出した「おすすめのアーティスト」。Artist.artworkURL は nil で
    /// gradient placeholder 表示にする(MVP)。
    var suggestedArtists: [Artist] = []

    let roomViewModel: RoomViewModel
    private var debounceTask: Task<Void, Never>?
    private static let recentSearchesKey = "pt.recentSearches"
    private static let recentSearchesMax = 8

    init(roomViewModel: RoomViewModel) {
        self.roomViewModel = roomViewModel
        loadRecentSearches()
        Task { await checkSubscription() }
    }

    // MARK: - Recent searches

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
    }

    private func saveRecentSearches() {
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    func addRecentSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > Self.recentSearchesMax {
            recentSearches = Array(recentSearches.prefix(Self.recentSearchesMax))
        }
        saveRecentSearches()
    }

    func removeRecentSearch(_ term: String) {
        recentSearches.removeAll { $0 == term }
        saveRecentSearches()
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        saveRecentSearches()
    }

    // MARK: - Empty state data

    /// 検索前画面用に「自分の最近」と「ふたりで最近」、おすすめアーティストを取得。
    /// SearchSheet が表示される直前(onAppear)に呼ぶ想定。
    func loadEmptyStateData() async {
        guard let userId = try? await SupabaseManager.shared.client.auth.session.user.id.uuidString else { return }
        let client = SupabaseManager.shared.client

        // 自分の最近(played_duration_seconds>=30 で ♥ 専用マーカー行を除外)
        do {
            myRecentTracks = try await client
                .from("my_room_play_history")
                .select()
                .eq("user_id", value: userId)
                .gte("played_duration_seconds", value: 30)
                .order("played_at", ascending: false)
                .limit(5)
                .execute()
                .value
        } catch {
            print("[SearchViewModel] loadEmptyStateData/myRecent error:", error)
        }

        // ふたりで最近(shared モード時のみ)
        let pairId = roomViewModel.sharedPairId
        if !pairId.isEmpty {
            do {
                sharedRecentTracks = try await client
                    .from("shared_room_play_history")
                    .select()
                    .eq("pair_id", value: pairId)
                    .order("played_at", ascending: false)
                    .limit(5)
                    .execute()
                    .value
            } catch {
                print("[SearchViewModel] loadEmptyStateData/sharedRecent error:", error)
            }
        } else {
            sharedRecentTracks = []
        }

        // おすすめのアーティスト: 履歴から top artists を抽出(出現頻度順、最大 6 件)
        // アーティスト画像は履歴に無いため、その artist の最新再生の artwork_url(アルバム
        // アート)を仮アバターとして流用する。Apple Music の artist artwork ID 取得は
        // 別途検索が必要だが、UX としては「最近聴いたアルバム」が見える方が自然。
        let combined = sharedRecentTracks + myRecentTracks
        var counts: [String: Int] = [:]
        var firstArtwork: [String: String] = [:]   // artistName → 最新の artwork_url
        var order: [String] = []
        for entry in combined {
            let key = entry.artistName
            counts[key, default: 0] += 1
            if firstArtwork[key] == nil, let art = entry.artworkUrl {
                firstArtwork[key] = art
            }
            if !order.contains(key) { order.append(key) }
        }
        let sorted = order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        suggestedArtists = sorted.prefix(6).map { name in
            let url = firstArtwork[name].flatMap(URL.init(string:))
            return Artist(id: "history-\(name)", name: name, artworkURL: url)
        }
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
            playlists = []
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

    /// TextField .onSubmit から呼ぶ。確定したクエリのみ「最近の検索」に追加する。
    func submitSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addRecentSearch(trimmed)
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

    /// 日本語の文字(ひらがな/カタカナ/CJK 漢字)が含まれているかを判定。
    /// ストアフロントを `jp` に強制するためのヒューリスティック。
    /// 端末ロケールが US の場合でも、日本語クエリでは jp カタログを検索したい。
    private static func containsJapanese(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x309F).contains(v) ||   // Hiragana
               (0x30A0...0x30FF).contains(v) ||   // Katakana
               (0x4E00...0x9FFF).contains(v) ||   // CJK Unified Ideographs
               (0xFF66...0xFF9F).contains(v) {    // Half-width katakana
                return true
            }
        }
        return false
    }

    private func search(_ query: String) async {
        // 日本語クエリは jp ストアフロント固定にしないと、US 等のストアフロントで
        // 日本のアーティストがヒットしないことがある。
        let storefront: String
        if Self.containsJapanese(query) {
            storefront = "jp"
        } else {
            storefront = Locale.current.region?.identifier.lowercased() ?? "jp"
        }
        // URLComponents で組み立てて、queryItems のエスケープを正しく行う。
        // 旧実装の "include[songs]" は `[`/`]` が URL ホストパース時に弾かれて
        // URL(string:) が nil を返したり、Apple Music API が 400 を返すことがあったので
        // queryItems で構築する方が安全。
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = "/v1/catalog/\(storefront)/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "types", value: "songs,artists,playlists"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "l", value: "ja-JP"),
            URLQueryItem(name: "include[songs]", value: "albums,artists"),
        ]
        // URLComponents は `[`/`]` を encode しないので、percentEncodedQuery を上書きして
        // 確実に %5B / %5D にする。
        if let percentQuery = components.percentEncodedQuery {
            components.percentEncodedQuery = percentQuery
                .replacingOccurrences(of: "[", with: "%5B")
                .replacingOccurrences(of: "]", with: "%5D")
        }
        guard let url = components.url else {
            isSearching = false
            return
        }
        do {
            let dataResponse = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            try Task.checkCancellation()
            let decoded = try JSONDecoder().decode(AppleMusicSearchResponse.self, from: dataResponse.data)
            songs = decoded.results.songs?.data.compactMap { $0.toTrack() } ?? []
            // Artist には検索に使った storefront を埋め込む。後段の ArtistDetail /
            // ArtistAllSongs が同じ storefront に対して /artists/{id}/... を叩けるように
            // する(別ストアフロントで artistID が無効になり 500/404 になる事象を回避)。
            artists = decoded.results.artists?.data.compactMap { resource in
                var a = resource.toArtist()
                a?.storefront = storefront
                return a
            } ?? []
            playlists = decoded.results.playlists?.data.compactMap { resource in
                var p = resource.toPlaylist()
                p?.storefront = storefront
                return p
            } ?? []
            searchError = nil
            // 履歴には保存しない。確定(TextField .onSubmit)時のみ submitSearch() で追加する。
        } catch is CancellationError {
            return
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return
        } catch {
            print("[SearchViewModel] search error:", error)
            songs = []
            artists = []
            playlists = []
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
        let playlists: Playlists?
    }

    struct Songs: Decodable {
        let data: [SongResource]
    }

    struct Artists: Decodable {
        let data: [ArtistResource]
    }

    struct Playlists: Decodable {
        let data: [PlaylistResource]
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

    struct PlaylistResource: Decodable {
        let id: String
        let attributes: PlaylistAttributes?

        func toPlaylist() -> Playlist? {
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
                artworkURL: artworkURL
            )
        }
    }

    struct PlaylistAttributes: Decodable {
        let name: String
        let curatorName: String?
        let artwork: ArtworkInfo?
    }

    struct ArtworkInfo: Decodable {
        let url: String
    }
}
