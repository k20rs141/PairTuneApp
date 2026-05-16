import SwiftUI

struct SearchSheet: View {
    @Binding var isPresented: Bool
    var viewModel: SearchViewModel
    /// Shared モードで partner がいる時のみ「相手に送る」CTA / Action sheet を表示する。
    var partnerName: String? = nil
    /// 設定すると、曲タップ時のデフォルト挙動(viewModel.selectSong = playAsHost)を
    /// 上書きする。QueueSheet の「+ 追加」から開いた時に「再生せずキューに追加」する
    /// ために使う。
    var onSelectTrack: ((Track) -> Void)? = nil

    @State private var query: String = ""
    @State private var navPath = NavigationPath()
    @State private var contextTrack: Track?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color.pairtuneSurface.ignoresSafeArea()
                searchRoot

                if let track = contextTrack {
                    TrackContextMenu(
                        track: track,
                        partnerName: partnerName,
                        onClose: { contextTrack = nil },
                        onFavorite: {
                            Task { await viewModel.addFavorite(track) }
                        },
                        onSendToPartner: {
                            isPresented = false
                            viewModel.selectSong(track)
                        },
                        onPlayNext: {
                            // 「次に再生」は再生せずに現再生の直後にキュー挿入する。
                            Task { await viewModel.playNext(track) }
                        },
                        onShowAlbum: track.albumId.map { albumId in
                            {
                                navPath.append(Album(
                                    id: albumId,
                                    title: track.album,
                                    artistName: track.artist,
                                    artworkURL: track.artworkURL
                                ))
                            }
                        },
                        onShowArtist: track.artistId.map { artistId in
                            {
                                navPath.append(Artist(
                                    id: artistId,
                                    name: track.artist,
                                    artworkURL: nil
                                ))
                            }
                        }
                    )
                    .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(
                    viewModel: ArtistDetailViewModel(artist: artist, roomViewModel: viewModel.roomViewModel),
                    partnerName: partnerName,
                    onSelectTrack: { track in
                        isPresented = false
                        // onSelectTrack override が設定されていればそちら(enqueue)を優先。
                        if let onSelectTrack {
                            onSelectTrack(track)
                        } else {
                            viewModel.selectSong(track)
                        }
                    },
                    onSelectAlbum: { album in
                        navPath.append(album)
                    },
                    onSelectPlaylist: { playlist in
                        navPath.append(playlist)
                    },
                    onSendArtistToPartner: partnerName != nil ? {
                        isPresented = false
                    } : nil
                )
            }
            .navigationDestination(for: Playlist.self) { playlist in
                AlbumDetailView(
                    viewModel: AlbumDetailViewModel(playlist: playlist, roomViewModel: viewModel.roomViewModel),
                    partnerName: partnerName,
                    onSelectTrack: { track in
                        isPresented = false
                        if let onSelectTrack {
                            onSelectTrack(track)
                        } else {
                            viewModel.selectSong(track)
                        }
                    },
                    onShowArtist: { artist in
                        navPath.append(artist)
                    }
                )
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(
                    viewModel: AlbumDetailViewModel(album: album, roomViewModel: viewModel.roomViewModel),
                    partnerName: partnerName,
                    onSelectTrack: { track in
                        isPresented = false
                        if let onSelectTrack {
                            onSelectTrack(track)
                        } else {
                            viewModel.selectSong(track)
                        }
                    },
                    onShowArtist: { artist in
                        navPath.append(artist)
                    }
                )
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            query = ""
            viewModel.songs = []
            viewModel.artists = []
            viewModel.playlists = []
            viewModel.isSearching = false
            // 検索前画面の最近履歴・おすすめを読み込む(SoloMode/Shared 自動判定)
            Task { await viewModel.loadEmptyStateData() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                searchFocused = true
            }
        }
    }

    // MARK: - Root

    private var searchRoot: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.white.opacity(0.18))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 18)

            // Search bar + cancel
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundColor(.pairtuneTextTertiary)
                        .padding(.leading, 12)

                    TextField("曲名・アーティスト  ·  Songs, artists", text: $query)
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .tint(.pairtuneCoral)
                        .focused($searchFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .onChange(of: query) { _, new in viewModel.onSearchTextChanged(new) }
                        .onSubmit {
                            // Enter / search キー押下時のみ「最近の検索」に保存。
                            viewModel.submitSearch(query)
                        }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: "1F1F1F"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                        )
                )
                .frame(height: 40)

                Button {
                    isPresented = false
                } label: {
                    Text("キャンセル")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.pairtuneCoral)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            // Results
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.subscriptionMissing {
                        EmptyStateView(
                            kind: .authError,
                            transparentBackground: true,
                            onAction: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        )
                        .frame(height: 480)
                    } else if viewModel.isOffline {
                        EmptyStateView(
                            kind: .offline,
                            transparentBackground: true,
                            onAction: { viewModel.retrySearch() }
                        )
                        .frame(height: 480)
                    } else if viewModel.isSearching {
                        ForEach(0..<5, id: \.self) { _ in
                            SkeletonRow()
                        }
                    } else if viewModel.songs.isEmpty && viewModel.artists.isEmpty && viewModel.playlists.isEmpty && !query.isEmpty {
                        EmptyStateView(
                            kind: .noResults,
                            descriptionOverride: "「\(query)」に一致する曲は見つかりませんでした。",
                            transparentBackground: true,
                            onAction: {
                                query = ""
                                searchFocused = true
                            }
                        )
                        .frame(height: 480)
                    } else if query.isEmpty {
                        // §2.6.1 検索前画面: 最近の検索 + 履歴 + おすすめアーティスト
                        SearchEmptyState(
                            viewModel: viewModel,
                            isSolo: partnerName == nil,
                            onRecentTap: { term in
                                query = term
                            },
                            onTrack: { track in
                                isPresented = false
                                if let onSelectTrack {
                                    onSelectTrack(track)
                                } else {
                                    viewModel.selectSong(track)
                                }
                            },
                            onArtist: { artist in
                                navPath.append(artist)
                            }
                        )
                    } else {
                        if !viewModel.artists.isEmpty {
                            sectionHeader("アーティスト · Artists")
                                .padding(.bottom, 12)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(viewModel.artists) { artist in
                                        NavigationLink(value: artist) {
                                            ArtistAvatarCell(artist: artist)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 18)
                            }
                            .padding(.bottom, 18)

                            if !viewModel.songs.isEmpty {
                                Divider()
                                    .background(Color.pairtuneHairline)
                                    .padding(.horizontal, 18)
                                    .padding(.bottom, 14)
                            }
                        }

                        if !viewModel.songs.isEmpty {
                            sectionHeader("曲 · Songs")
                                .padding(.bottom, 4)
                            ForEach(viewModel.songs) { track in
                                Button {
                                    isPresented = false
                                    if let onSelectTrack {
                                        onSelectTrack(track)
                                    } else {
                                        viewModel.selectSong(track)
                                    }
                                } label: {
                                    TrackRow(track: track)
                                }
                                // highPriorityGesture を使うと Button の tap が
                                // 長押し成立時にキャンセルされ、両方が発火する問題
                                // (simultaneousGesture)を回避できる。
                                .highPriorityGesture(
                                    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                                        contextTrack = track
                                    }
                                )
                            }
                        }

                        if !viewModel.playlists.isEmpty {
                            if !viewModel.artists.isEmpty || !viewModel.songs.isEmpty {
                                Divider()
                                    .background(Color.pairtuneHairline)
                                    .padding(.horizontal, 18)
                                    .padding(.bottom, 14)
                            }
                            sectionHeader("プレイリスト · Playlists")
                                .padding(.bottom, 12)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(viewModel.playlists) { playlist in
                                        NavigationLink(value: playlist) {
                                            SearchPlaylistCell(playlist: playlist)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 18)
                            }
                            .padding(.bottom, 18)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.pairtuneTextTertiary)
                .tracking(0.6)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Track row

private struct TrackRow: View {
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = track.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
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
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.system(size: 12.5))
                    .foregroundColor(.pairtuneTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(fmt(track.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.pairtuneTextTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Artist avatar cell

private struct ArtistAvatarCell: View {
    let artist: Artist

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let url = artist.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)

            Text(artist.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 88)
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color.pairtuneCoral.opacity(0.55), Color(hex: "4A1D3D")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "person.fill")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.7))
        )
    }
}

// MARK: - Playlist cell (search results, same width as ArtistAvatarCell)

private struct SearchPlaylistCell: View {
    let playlist: Playlist

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let url = playlist.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)

            VStack(spacing: 2) {
                Text(playlist.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 88)
                if !playlist.curatorName.isEmpty {
                    Text(playlist.curatorName)
                        .font(.system(size: 10.5))
                        .foregroundColor(.pairtuneTextSecondary)
                        .lineLimit(1)
                        .frame(width: 88)
                }
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color.pairtuneSecondary.opacity(0.55), Color(hex: "4A1D3D")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.7))
        )
    }
}

// MARK: - Skeleton row

private struct SkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: "1F1F1F"))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: "1F1F1F"))
                    .frame(width: 140, height: 13)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: "1A1A1A"))
                    .frame(width: 90, height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .opacity(shimmer ? 0.4 : 0.9)
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}

// MARK: - Search empty state (検索前画面 §2.6.1)
//
// 検索バーが空の時に表示。design: /tmp/pairtune-design-v3/music-app/project/screens-search.jsx
// セクション:
//   1. 最近の検索(chips、× / すべて削除)
//   2. ふたりで最近聴いた曲(shared モードのみ)
//   3. あなた/最近聴いた曲(常に表示。Solo時は「最近聴いた曲」)
//   4. おすすめのアーティスト(履歴の top artists、horizontal)
//   5. フッターヒント文

private struct SearchEmptyState: View {
    @Bindable var viewModel: SearchViewModel
    let isSolo: Bool
    var onRecentTap: (String) -> Void
    var onTrack: (Track) -> Void
    var onArtist: (Artist) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.recentSearches.isEmpty {
                recentSearchesSection
            }

            if !isSolo && !viewModel.sharedRecentTracks.isEmpty {
                sectionHeader("ふたりで最近聴いた曲", "Recently together", icon: "music.note")
                ForEach(viewModel.sharedRecentTracks) { entry in
                    HistoryRow(entry: entry, onTap: { onTrack(entry.toTrack()) })
                }
            }

            if !viewModel.myRecentTracks.isEmpty {
                sectionHeader(
                    isSolo ? "最近聴いた曲" : "あなたが最近聴いた曲",
                    "Your recent plays",
                    icon: "clock"
                )
                ForEach(viewModel.myRecentTracks) { entry in
                    HistoryRow(entry: entry, onTap: { onTrack(entry.toTrack()) })
                }
            }

            if !viewModel.suggestedArtists.isEmpty {
                sectionHeader("おすすめのアーティスト", "For you · Artists")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(viewModel.suggestedArtists) { artist in
                            Button { onArtist(artist) } label: {
                                ArtistChipView(artist: artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
            }

            // 全部空のケースは初回起動時。説明文だけ出す。
            let allEmpty = viewModel.recentSearches.isEmpty
                && viewModel.sharedRecentTracks.isEmpty
                && viewModel.myRecentTracks.isEmpty
                && viewModel.suggestedArtists.isEmpty
            if allEmpty {
                Text("曲名やアーティスト名で検索してください。")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "7A7588"))
                    .padding(.horizontal, 22)
                    .padding(.top, 40)
            }

            Text(isSolo
                ? "あなたが最近聴いた曲から提案しています。"
                : "ふたりで聴いた曲と、ペアの好みを参考に提案しています。")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "5A5566"))
                .lineSpacing(3)
                .tracking(0.2)
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Recent searches

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("最近の検索")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .tracking(0.3)
                    Text("· RECENT")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "5A5566"))
                        .tracking(0.6)
                }
                Spacer()
                Button { viewModel.clearRecentSearches() } label: {
                    Text("すべて削除")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "7A7588"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 10)

            FlowLayout(spacing: 8) {
                ForEach(viewModel.recentSearches, id: \.self) { term in
                    RecentSearchChip(
                        term: term,
                        onTap: { onRecentTap(term) },
                        onRemove: { viewModel.removeRecentSearch(term) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Section header (inline style: <日本語> · ENGLISH UPPERCASE)

    private func sectionHeader(_ ja: String, _ en: String, icon: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "A8A8A8"))
            }
            Text(ja)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .tracking(0.2)
            Text("· \(en)")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "5A5566"))
                .tracking(0.7)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// MARK: - Recent search chip

private struct RecentSearchChip: View {
    let term: String
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "7A7588"))
                    Text(term)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white)
                        .tracking(0.2)
                }
            }
            .buttonStyle(.plain)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(hex: "7A7588"))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        )
    }
}

// MARK: - History row (TrackRow と同じだが PlayHistoryEntry 専用)

private struct HistoryRow: View {
    let entry: PlayHistoryEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Group {
                    if let urlStr = entry.artworkUrl, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                            default: gradientPlaceholder
                            }
                        }
                    } else {
                        gradientPlaceholder
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.songTitle)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(entry.artistName)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "A8A8A8"))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var gradientPlaceholder: some View {
        LinearGradient(
            colors: [Color.pairtunePrimary.opacity(0.55), Color(hex: "1F1830")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Artist chip (78pt circle + name label)

private struct ArtistChipView: View {
    let artist: Artist

    var body: some View {
        VStack(spacing: 8) {
            artworkCircle
            Text(artist.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white)
                .tracking(0.4)
                .lineLimit(1)
                .frame(maxWidth: 90)
        }
    }

    @ViewBuilder
    private var artworkCircle: some View {
        let placeholder = ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: gradientColors(seed: artist.name),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "person.fill")
                .font(.system(size: 32))
                .foregroundColor(Color.white.opacity(0.6))
        }

        Group {
            if let url = artist.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 78, height: 78)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }

    /// name から決定論的に gradient 色ペアを選ぶ。
    private func gradientColors(seed: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(hex: "9B7BFF"), Color(hex: "2E0E2A")],
            [Color(hex: "FF6B9D"), Color(hex: "4A0A2E")],
            [Color(hex: "C49AF4"), Color(hex: "4A1D5E")],
            [Color(hex: "6BB6F0"), Color(hex: "1D3B4A")],
            [Color(hex: "F4C26A"), Color(hex: "B8753C")],
            [Color(hex: "7BD389"), Color(hex: "1D4A2E")],
        ]
        let hash = abs(seed.hashValue)
        return palettes[hash % palettes.count]
    }
}

// MARK: - FlowLayout (chips wrap)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
