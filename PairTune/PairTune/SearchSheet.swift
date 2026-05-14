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
                    onSendArtistToPartner: partnerName != nil ? {
                        isPresented = false
                    } : nil
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
            viewModel.isSearching = false
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
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .onChange(of: query) { _, new in viewModel.onSearchTextChanged(new) }
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

            // Section header (when not searching)
            if query.isEmpty {
                HStack {
                    Text("最近聴いた曲 · Recently played")
                        .font(.system(size: 11))
                        .foregroundColor(.pairtuneTextTertiary)
                        .tracking(0.6)
                        .textCase(.uppercase)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
            }

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
                    } else if viewModel.songs.isEmpty && viewModel.artists.isEmpty && !query.isEmpty {
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
