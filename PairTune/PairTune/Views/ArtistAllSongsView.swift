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
    /// 初回ロード中(まだ曲が 0 件)
    var isLoading: Bool = false
    /// 追加ロード中(末尾までスクロールして次のページを取得中)
    var isLoadingMore: Bool = false
    /// これ以上ページがあるか。false になったらフッタに「N 曲」を出す。
    var hasMore: Bool = true
    var loadError: String?

    private let roomViewModel: RoomViewModel
    private var loadTask: Task<Void, Never>?

    // MARK: - Pagination state

    private let pageSize: Int = 20
    /// /songs エンドポイント用の次の offset
    private var nextSongsOffset: Int = 0
    /// 重複 song_id の追加を防ぐ
    private var seenSongIds: Set<String> = []

    init(artist: Artist, roomViewModel: RoomViewModel) {
        self.artist = artist
        self.roomViewModel = roomViewModel
    }

    /// 初回ロード(View の onAppear / .task から呼ぶ)。
    func load() {
        guard !isLoading, !isLoadingMore, songs.isEmpty else { return }
        isLoading = true
        loadError = nil
        loadTask?.cancel()
        loadTask = Task {
            await fetchNextPage()
            isLoading = false
        }
    }

    /// 末尾までスクロールした時に呼ぶ。追加で次の 1 ページを取得。
    func loadMore() {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        loadTask?.cancel()
        loadTask = Task {
            await fetchNextPage()
            isLoadingMore = false
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

    // MARK: - Page fetch

    /// /artists/{id}/songs から次のページ(pageSize 件)を取得して append。
    /// 失敗時:
    ///   - 1 件も曲が取れていない → loadError をセットして UI に「読み込みできません」を出す
    ///   - 既に表示済みあり → これ以上は追わずページネーション終了
    private func fetchNextPage() async {
        // artistID が取得されたストアフロントに合わせて API を叩く。検索由来なら
        // artist.storefront がセットされている。無ければ端末ロケールにフォールバック。
        let storefront = artist.storefront
            ?? Locale.current.region?.identifier.lowercased()
            ?? "jp"
        do {
            let pageTracks = try await Self.fetchSongsPage(
                storefront: storefront,
                artistID: artist.id,
                limit: pageSize,
                offset: nextSongsOffset
            )
            for t in pageTracks where seenSongIds.insert(t.id).inserted {
                songs.append(t)
            }
            nextSongsOffset += pageSize
            if pageTracks.count < pageSize {
                hasMore = false
            }
        } catch is CancellationError {
            return
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return
        } catch {
            print("[ArtistAllSongsViewModel] /songs page failed at offset \(nextSongsOffset):", error.localizedDescription)
            if songs.isEmpty {
                loadError = "読み込みできません。リトライしてください"
            }
            hasMore = false
        }
    }

    // MARK: - Static fetch helpers

    /// 1 ページ分を取得する。Apple Music API の一時的な 5xx(Internal Service Error)に
    /// 対応するため最大 3 回まで指数バックオフでリトライ。最終リトライでも失敗したら、
    /// `include=albums,artists` を外して再試行(include パラメータ自体が
    /// 特定アーティストで 500 を誘発するケースがあるため)。include を外した場合は
    /// albumId / artistId が nil になり TrackContextMenu のアルバム/アーティスト遷移は
    /// 効かなくなるが、曲リスト自体は表示できる。
    private static func fetchSongsPage(
        storefront: String,
        artistID: String,
        limit: Int,
        offset: Int
    ) async throws -> [Track] {
        let urlWithInclude = "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/songs?limit=\(limit)&offset=\(offset)&l=ja-JP&include=albums,artists"
        let urlWithoutInclude = "https://api.music.apple.com/v1/catalog/\(storefront)/artists/\(artistID)/songs?limit=\(limit)&offset=\(offset)&l=ja-JP"

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await requestPage(urlStr: urlWithInclude, fallbackArtistID: artistID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                print("[ArtistAllSongsViewModel] offset \(offset) attempt \(attempt + 1)/3 failed:", error.localizedDescription)
                // 最終アテンプトでなければバックオフして再試行
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                }
            }
        }

        // include 付きで 3 回失敗 → include 無しで 1 回だけ試す
        print("[ArtistAllSongsViewModel] retry exhausted with include=, falling back to plain endpoint")
        do {
            return try await requestPage(urlStr: urlWithoutInclude, fallbackArtistID: artistID)
        } catch {
            print("[ArtistAllSongsViewModel] fallback also failed:", error.localizedDescription)
            throw lastError ?? error
        }
    }

    /// 単発の Apple Music API リクエスト → デコード。
    private static func requestPage(urlStr: String, fallbackArtistID: String) async throws -> [Track] {
        guard let url = URL(string: urlStr) else { return [] }
        let resp = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        try Task.checkCancellation()
        let decoded = try JSONDecoder().decode(SongsResponse.self, from: resp.data)
        return decoded.data?.compactMap { $0.toTrack(fallbackArtistID: fallbackArtistID) } ?? []
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
                                .onAppear {
                                    // 末尾の行が画面に現れたら次ページを取りに行く。
                                    // viewModel.loadMore() 側で in-flight ガード済みなので
                                    // 過剰呼び出しは抑制される。
                                    if track.id == viewModel.songs.last?.id {
                                        viewModel.loadMore()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)

                        // 末尾フッタ:
                        //  - 追加ロード中 → ProgressView
                        //  - これ以上無し  → 「N 曲」総数表示
                        Group {
                            if viewModel.isLoadingMore {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .controlSize(.small)
                                        .tint(.pairtuneTextSecondary)
                                    Text("読み込み中…")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "5A5566"))
                                }
                                .padding(.vertical, 18)
                            } else if !viewModel.hasMore {
                                Text("\(viewModel.songs.count) 曲")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "5A5566"))
                                    .padding(.top, 12)
                                    .padding(.bottom, 24)
                            }
                        }
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

