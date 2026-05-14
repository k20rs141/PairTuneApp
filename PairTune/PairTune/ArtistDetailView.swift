import SwiftUI

// MARK: - ArtistDetailView (v0.4 §2.7 / v1.1 refresh)
//
// Apple Music の Artist 画面を PairTune に翻案。
// - 440pt full-bleed hero(背景: アーティスト artwork、または primary→base のグラデ)
// - スクロール 55% で FloatingNav が compact モード(blurred, タイトル小表示)へ
// - Latest release カード(albums 先頭)
// - Top Songs リスト(album-strip サムネ付き)
// - 「相手に送る」CTA(shared モード時のみ)

struct ArtistDetailView: View {
    @State var viewModel: ArtistDetailViewModel
    /// shared モード + partner ありの時のみ「相手に送る」CTA を表示する。
    var partnerName: String?
    var onSelectTrack: (Track) -> Void
    var onSelectAlbum: ((Album) -> Void)? = nil
    var onSendArtistToPartner: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var scrollOffset: CGFloat = 0
    @State private var contextTrack: Track?

    private let heroHeight: CGFloat = 440

    private var heroAlpha: Double {
        max(0, 1 - Double(scrollOffset) / Double(heroHeight))
    }

    private var compactNav: Bool { heroAlpha < 0.2 }

    var body: some View {
        ZStack {
            Color.pairtuneSurface.ignoresSafeArea()

            scrollContent

            // Floating chrome over hero
            VStack(spacing: 0) {
                floatingNav
                Spacer()
            }
            .ignoresSafeArea(edges: .top)

            // Track context menu overlay
            if let track = contextTrack {
                TrackContextMenu(
                    track: track,
                    partnerName: partnerName,
                    onClose: { contextTrack = nil },
                    onSendToPartner: { viewModel.selectSong(track) },
                    onPlayNext: { viewModel.selectSong(track) },
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
        .navigationBarHidden(true)
        .task {
            if viewModel.topSongs.isEmpty && viewModel.albums.isEmpty {
                viewModel.load()
            }
        }
    }

    // MARK: - Scroll body

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .frame(height: heroHeight)

                if viewModel.isLoading && viewModel.topSongs.isEmpty && viewModel.albums.isEmpty {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.pairtuneTextSecondary)
                        .padding(.top, 40)
                } else {
                    if let latest = viewModel.latestAlbum {
                        latestReleaseCard(latest)
                            .padding(.horizontal, 18)
                            .padding(.top, 20)
                            .padding(.bottom, 6)
                    }

                    if !viewModel.topSongs.isEmpty {
                        topSongsHeader
                            .padding(.horizontal, 18)
                            .padding(.top, 24)
                            .padding(.bottom, 6)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.topSongs.enumerated()), id: \.element.id) { idx, track in
                                Button {
                                    onSelectTrack(track)
                                } label: {
                                    ArtistTrackRow(
                                        track: track,
                                        onMenu: { contextTrack = track }
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !viewModel.albums.isEmpty {
                        sectionHeader("アルバム", "ALBUMS")
                            .padding(.top, 22)
                            .padding(.bottom, 12)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(viewModel.albums) { album in
                                    Button {
                                        onSelectAlbum?(album)
                                    } label: {
                                        AlbumCardView(album: album)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                    }

                    if let onSendArtistToPartner, let partnerName, !partnerName.isEmpty {
                        sendToPartnerCTA(partnerName: partnerName, action: onSendArtistToPartner)
                            .padding(.horizontal, 18)
                            .padding(.top, 24)
                            .padding(.bottom, 36)
                    } else {
                        Spacer(minLength: 36)
                    }

                    if let err = viewModel.loadError {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.pairtuneSyncBad)
                            .padding(.top, 12)
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self,
                        value: -geo.frame(in: .named("artistScroll")).minY
                    )
                }
            )
        }
        .coordinateSpace(name: "artistScroll")
        .scrollIndicators(.hidden)
        .onPreferenceChange(ScrollOffsetKey.self) { v in
            scrollOffset = max(0, v)
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // background: artist artwork or gradient
            Group {
                if let url = viewModel.artist.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default: heroGradient
                        }
                    }
                } else {
                    heroGradient
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // bottom fade to base
            LinearGradient(
                colors: [Color.clear, Color.pairtuneSurface],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            HStack(alignment: .bottom) {
                Text(viewModel.artist.name)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundColor(.white)
                    .kerning(-0.8)
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 12)

                Button {
                    if let first = viewModel.topSongs.first { onSelectTrack(first) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.pairtunePrimary, .pairtuneSecondary],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: Color.pairtunePrimary.opacity(0.4), radius: 16, y: 8)
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.topSongs.isEmpty)
                .opacity(viewModel.topSongs.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
    }

    private var heroGradient: some View {
        LinearGradient(
            colors: [
                Color(hex: "6B7A95"),
                Color(hex: "364152"),
                Color.pairtuneSurface,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Floating nav

    private var floatingNav: some View {
        let bg: AnyShapeStyle = compactNav
            ? AnyShapeStyle(Color.pairtuneSurface.opacity(0.94))
            : AnyShapeStyle(Color.clear)

        return ZStack {
            Rectangle()
                .fill(bg)
                .overlay(alignment: .bottom) {
                    if compactNav {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 0.5)
                    }
                }
                .background(.ultraThinMaterial.opacity(compactNav ? 1 : 0))

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(compactNav ? .white : Color(hex: "0A0612"))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(compactNav ? Color.white.opacity(0.08) : Color.white.opacity(0.78))
                                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                if compactNav {
                    Text(viewModel.artist.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .tracking(0.2)
                        .lineLimit(1)
                    Spacer()
                }

                HStack(spacing: 0) {
                    Button { } label: {
                        Image(systemName: "star")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(compactNav ? .white : Color(hex: "0A0612"))
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(compactNav ? Color.white.opacity(0.15) : Color(hex: "0A0612").opacity(0.15))
                        .frame(width: 1, height: 14)

                    Button { } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(compactNav ? .white : Color(hex: "0A0612"))
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .background(
                    Capsule()
                        .fill(compactNav ? Color.white.opacity(0.08) : Color.white.opacity(0.78))
                        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                )
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 56)
        .padding(.top, 44)
        .animation(.easeInOut(duration: 0.25), value: compactNav)
    }

    // MARK: - Latest release card

    private func latestReleaseCard(_ album: Album) -> some View {
        Button {
            onSelectAlbum?(album)
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let url = album.artworkURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default: albumPlaceholder
                            }
                        }
                    } else { albumPlaceholder }
                }
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text("最新リリース")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "7A7588"))
                        .tracking(0.3)
                    Text(album.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(album.artistName)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "7A7588"))
                        .lineLimit(1)

                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.pairtunePrimary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    Circle().stroke(Color.pairtunePrimary.opacity(0.25), lineWidth: 0.5)
                                )
                        )
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private var albumPlaceholder: some View {
        LinearGradient(
            colors: [Color.pairtunePrimary.opacity(0.7), Color(hex: "1F1830")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Top songs header

    private var topSongsHeader: some View {
        HStack(spacing: 6) {
            Text("トップソング")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .tracking(0.2)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "7A7588"))
            Text("TOP SONGS")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "5A5566"))
                .tracking(0.5)
                .padding(.leading, 4)
            Spacer()
        }
    }

    private func sectionHeader(_ ja: String, _ en: String) -> some View {
        HStack(spacing: 6) {
            Text(ja)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .tracking(0.2)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "7A7588"))
            Text(en)
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "5A5566"))
                .tracking(0.5)
                .padding(.leading, 4)
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Send-to-partner CTA

    private func sendToPartnerCTA(partnerName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.pairtunePrimary)
                Text("\(partnerName) さんに送る")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.white)
                Text("· Send to partner")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scroll offset PreferenceKey

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Artist track row (Apple Music style w/ right strip thumb)

private struct ArtistTrackRow: View {
    let track: Track
    var starred: Bool = false
    var onMenu: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // optional star marker (top-track highlight)
            ZStack {
                if starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.pairtuneSecondary)
                }
            }
            .frame(width: 8)

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
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.white)
                    .tracking(0.1)
                    .lineLimit(1)
                Text(track.album)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "7A7588"))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "5A5566"))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 0.5)
                .padding(.leading, 68)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Album card (horizontal scroll)

private struct AlbumCardView: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let url = album.artworkURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default: placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(album.artistName)
                    .font(.system(size: 11))
                    .foregroundColor(.pairtuneTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color.pairtunePrimary.opacity(0.55), Color(hex: "1F1830")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
