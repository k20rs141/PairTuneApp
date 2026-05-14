import SwiftUI

// MARK: - SoloModeView (v0.4 Solo モード詳細 UI)
//
// 仕様: docs/PairTune_Specification_v0.4.md §7-3 / §7-4
// デザイン: Claude Design v2 `screens-solo.jsx`
//
// Home → Solo ボタンタップで遷移するスクリーン。
// セクション構成:
//   - ヘッダー(退室 / タイトル / 検索)
//   - NowPlaying カード(最後に聴いた曲 or muted)
//   - Nudge / MemoryRibbon / DeletedNote (状態別)
//   - ふたりで聴いた曲 (carousel、ペア時のみ)
//   - パートナーのお気に入り (opt-in、partner.shareFavorites = true のみ)
//   - あなたが最近聴いた曲 (list、常に表示)
//
// 状態 (SoloState):
//   - .pre: ペア無し → Nudge 表示
//   - .empty: ペア有り、共有履歴なし → Together セクションは EmptyState
//   - .full: ペア有り、共有履歴あり → 全セクション表示

enum SoloState {
    case pre
    case empty
    case full
}

struct SoloModeView: View {
    let viewModel: SoloHistoryViewModel
    let partnerName: String?
    let hasPair: Bool
    let partnerSharesFavorites: Bool
    let userId: String
    let pairId: String?

    var onExit: () -> Void
    /// 曲を再生してルームを開く。nil の場合は最後に聴いた曲(myRecent.first)を再生。
    /// 履歴が空で nil 渡しなら検索モーダルを開く挙動にフォールバックする(caller 側で判断)。
    var onPlayTrack: (PlayHistoryEntry?) -> Void
    /// 検索モーダルを開く(ルームを開かず SearchSheet を直接表示)。
    var onSearch: () -> Void
    var onPair: () -> Void

    private var state: SoloState {
        if !hasPair { return .pre }
        return viewModel.sharedHistory.isEmpty ? .empty : .full
    }

    @State private var contextEntry: PlayHistoryEntry?

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // Ambient glow — clipped to screen bounds so the 560pt circle doesn't expand the parent
            Color.clear
                .overlay(alignment: .top) {
                    Circle()
                        .fill(Color.pairtunePrimary.opacity(state == .pre ? 0.10 : 0.17))
                        .frame(width: 560, height: 560)
                        .blur(radius: 60)
                        .offset(y: -260)
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 0) {
                    header
                    nowPlayingCard
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 22) {
                        if state == .pre {
                            nudgeCard
                        }

                        if hasPair {
                            togetherSection
                        }

                        if hasPair && partnerSharesFavorites {
                            partnerFavoritesSection
                        }

                        myRecentSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 56)
                }
            }

            if let entry = contextEntry {
                // shared_room_play_history のエントリ(pairId が立っている)は
                // パートナーとの共有メモリなので「履歴から削除」は出さない(§8-5-2)。
                let isMyRecent = entry.pairId == nil
                TrackContextMenu(
                    track: entry.toTrack(),
                    partnerName: partnerName,
                    onClose: { contextEntry = nil },
                    onSendToPartner: { onPlayTrack(entry) },
                    onPlayNext: { onPlayTrack(entry) },
                    onRemoveFromHistory: isMyRecent ? {
                        Task { await viewModel.deleteMyRecent(entry, userId: userId) }
                    } : nil
                )
                .transition(.opacity)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            // RoomView から pop してきた時にも履歴を最新化する。
            Task { await viewModel.load(pairId: pairId, userId: userId) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            iconButton(systemName: "rectangle.portrait.and.arrow.forward", action: onExit)
            Spacer()
            VStack(spacing: 1) {
                Text("ひとりで聴く")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .tracking(0.2)
                Text("SOLO · listen alone")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.6)
            }
            Spacer()
            iconButton(systemName: "magnifyingglass", action: onSearch)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(Color(hex: "A8A8A8"))
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                )
        }
    }

    // MARK: - NowPlaying card

    private var nowPlayingCard: some View {
        let lastTrack = viewModel.myRecent.first
        let muted = lastTrack == nil
        return Button(action: { primaryNowPlayingAction(lastTrack: lastTrack) }) {
            HStack(spacing: 14) {
                ArtworkThumb(url: lastTrack?.artworkUrl, size: 84, muted: muted)

                VStack(alignment: .leading, spacing: 2) {
                    Text(lastTrack?.songTitle ?? "何を聴きますか?")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(lastTrack?.artistName ?? "Pick a song to begin")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "A8A8A8"))
                        .lineLimit(1)
                    miniProgressBar(active: !muted)
                        .padding(.top, 6)
                }

                Spacer(minLength: 8)

                Button(action: { primaryNowPlayingAction(lastTrack: lastTrack) }) {
                    playOrSearchButton(muted: muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func primaryNowPlayingAction(lastTrack: PlayHistoryEntry?) {
        if let lastTrack {
            onPlayTrack(lastTrack)
        } else {
            onSearch()
        }
    }

    private func miniProgressBar(active: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.07))
                .frame(height: 2)
            if active {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 80, height: 2)
            }
        }
    }

    private func playOrSearchButton(muted: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    muted
                    ? AnyShapeStyle(Color.white.opacity(0.04))
                    : AnyShapeStyle(LinearGradient(
                        colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                )
                .frame(width: 46, height: 46)
                .overlay(
                    Circle().stroke(muted ? Color.white.opacity(0.10) : Color.clear, lineWidth: 0.5)
                )
                .shadow(color: muted ? .clear : Color.pairtunePrimary.opacity(0.33), radius: 14, y: 6)

            Image(systemName: muted ? "magnifyingglass" : "play.fill")
                .font(.system(size: muted ? 17 : 16, weight: .medium))
                .foregroundColor(.white)
        }
    }

    // MARK: - Together section

    @ViewBuilder
    private var togetherSection: some View {
        SectionHeader(
            icon: "music.note.list",
            title: "ふたりで聴いた曲",
            sub: "Together",
            accent: .pairtunePrimary,
            actionLabel: state == .full ? "もっと見る" : nil
        )

        if state == .empty {
            EmptyStateCard(
                title: "まだ一緒に聴いていません",
                hint: hasPair && partnerName != nil
                    ? "\(partnerName!) さんと部屋を開くと、ここに記録されます"
                    : "ペアと部屋を開くと、ここに記録されます",
                accent: .pairtunePrimary
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.sharedHistory) { entry in
                        Button(action: { onPlayTrack(entry) }) {
                            TrackCarouselCard(entry: entry, accent: .pairtunePrimary)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                                contextEntry = entry
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Partner favorites section

    @ViewBuilder
    private var partnerFavoritesSection: some View {
        SectionHeader(
            icon: "sparkles",
            title: "\(partnerName ?? "パートナー") さんの最近のお気に入り",
            sub: "Recent favorites · opt-in",
            accent: .pairtuneSecondary,
            chip: "OPT-IN"
        )

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // パートナーお気に入り API は v1.1 で実装。MVP では空表示。
                EmptyStateCard(
                    title: "まだ表示できません",
                    hint: "v1.1 で実装予定",
                    accent: .pairtuneSecondary
                )
                .frame(width: 280)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - My recent section

    @ViewBuilder
    private var myRecentSection: some View {
        SectionHeader(
            icon: "music.note",
            title: "あなたが最近聴いた曲",
            sub: "Your recent plays",
            accent: Color(hex: "7A7588")
        )

        if viewModel.myRecent.isEmpty {
            EmptyStateCard(
                title: "まだ聴いた曲がありません",
                hint: "曲を選んで再生すると、ここに記録されます",
                accent: Color(hex: "7A7588")
            )
        } else {
            VStack(spacing: 1) {
                ForEach(viewModel.myRecent) { entry in
                    Button(action: { onPlayTrack(entry) }) {
                        TrackListItem(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                            contextEntry = entry
                        }
                    )
                }
            }
        }
    }

    // MARK: - Nudge

    private var nudgeCard: some View {
        Button(action: onPair) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.pairtunePrimary.opacity(0.11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundColor(.pairtunePrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("パートナーとペアリング")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    Text("同じ音を、もっと一緒に楽しもう。")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "7A7588"))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "7A7588"))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary.opacity(0.08), Color.pairtuneSecondary.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.pairtunePrimary.opacity(0.27), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reusable subcomponents

private struct SectionHeader: View {
    let icon: String
    let title: String
    let sub: String
    let accent: Color
    var actionLabel: String? = nil
    var chip: String? = nil

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(accent.opacity(0.30), lineWidth: 0.5)
                    )
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.5)
            }

            if let chip {
                Text(chip)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(accent)
                    .tracking(0.7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(accent.opacity(0.11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(accent.opacity(0.30), lineWidth: 0.5)
                            )
                    )
            }

            Spacer()

            if let actionLabel {
                HStack(spacing: 3) {
                    Text(actionLabel)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "7A7588"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "7A7588"))
                }
            }
        }
    }
}

private struct TrackCarouselCard: View {
    let entry: PlayHistoryEntry
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkThumb(url: entry.artworkUrl, size: 108)
                .overlay(alignment: .topLeading) {
                    if entry.isFirstPlay == true {
                        Text("初めて")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.white)
                            .tracking(0.6)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(accent.opacity(0.8))
                            )
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.songTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(entry.artistName)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "7A7588"))
                    .lineLimit(1)
            }
            .frame(width: 108, alignment: .leading)
        }
        .frame(width: 108)
    }
}

private struct TrackListItem: View {
    let entry: PlayHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumb(url: entry.artworkUrl, size: 42, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.songTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(entry.artistName)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "7A7588"))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "play.fill")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "5A5566"))
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 0.5)
        }
    }
}

private struct ArtworkThumb: View {
    let url: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 12
    var muted: Bool = false

    var body: some View {
        Group {
            if let urlStr = url, let u = URL(string: urlStr) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: muted ? .clear : Color.black.opacity(0.45), radius: 12, y: 6)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "1F1A30"), Color(hex: "0F0C1C")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.30))
                .foregroundColor(Color(hex: "3A3548"))
        }
    }
}

private struct EmptyStateCard: View {
    let title: String
    let hint: String
    let accent: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .tracking(0.2)
            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "7A7588"))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accent.opacity(0.30), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                )
        )
    }
}
