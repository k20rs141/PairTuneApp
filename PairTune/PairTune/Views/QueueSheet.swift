import SwiftUI

// MARK: - QueueSheet (v0.4 §2.15)
//
// Room 画面のキューボタンから開く bottom sheet。
// セクション:
//   1. Now Playing — 現再生中(波形 + PLAYING chip)
//   2. Up Next     — キュー一覧(各行: # / art / 曲 / 追加者 / 長さ / ⋯)
//   3. Recently played — このセッション内の履歴(相対時刻)
//
// 操作:
//   - 行タップ: その曲へスキップ(roomViewModel.playFromQueue)
//   - ⋯: TrackContextMenu("次に再生" / "履歴から削除" 等)
//   - 「+ 追加」: 検索を開いて末尾に追加(現 mode 継承)
//   - drag handle: 並べ替え(.onMove)
//
// フッタ文言:
//   - Shared: 「どちらも追加・並び替え・削除ができます。最後の操作が優先されます。」
//   - Solo : 「キューはこの再生セッション内でのみ有効です。」

struct QueueSheet: View {
    @Bindable var roomViewModel: RoomViewModel
    var recentlyPlayed: [PlayHistoryEntry] = []
    /// Shared モード時の partner.displayName(追加者アバターのフォールバックラベル用)
    var partnerName: String? = nil
    var onAddTap: () -> Void
    var onDismiss: () -> Void

    @State private var contextTrack: Track?
    @State private var isReordering: Bool = false

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            VStack(spacing: 0) {
                handleBar
                headerBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        nowPlayingSection
                        upNextSection
                        if !recentlyPlayed.isEmpty {
                            recentlyPlayedSection
                        }
                        footer
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                }
            }

            if let track = contextTrack {
                TrackContextMenu(
                    track: track,
                    partnerName: partnerName,
                    onClose: { contextTrack = nil },
                    onFavorite: {
                        Task { await roomViewModel.addFavoriteToCatalog(track) }
                    },
                    onSendToPartner: {
                        Task { await roomViewModel.playAsHost(track) }
                    },
                    onPlayNext: {
                        Task { await roomViewModel.playNextInQueue(track) }
                    }
                )
                .transition(.opacity)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Top bar

    private var handleBar: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.white.opacity(0.18))
            .frame(width: 36, height: 5)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("再生キュー")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(0.2)
                Text(modeSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.6)
            }
            Spacer()
            Button(action: onAddTap) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("追加")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.pairtunePrimary, .pairtuneSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 10, y: 4)
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "A8A8A8"))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.05))
                            .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private var modeSubtitle: String {
        switch roomViewModel.mode {
        case .shared: return "QUEUE · SHARED"
        case .solo:   return "QUEUE · SOLO"
        }
    }

    // MARK: - Now playing

    @ViewBuilder
    private var nowPlayingSection: some View {
        sectionHeader(icon: "waveform", title: "再生中", sub: "NOW PLAYING", accent: .pairtuneSecondary)
        if let track = roomViewModel.currentTrack {
            HStack(spacing: 14) {
                artworkView(
                    url: track.artworkURL?.absoluteString,
                    size: 64,
                    accent: .pairtuneSecondary,
                    stops: track.gradientStops
                )
                .shadow(color: Color.pairtuneSecondary.opacity(0.27), radius: 14, y: 6)

                VStack(alignment: .leading, spacing: 4) {
                    playingChip
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "A8A8A8"))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtuneSecondary.opacity(0.16), Color.pairtunePrimary.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.pairtuneSecondary.opacity(0.30), lineWidth: 0.5)
                    )
            )
        } else {
            placeholderCard(text: "再生中の曲はありません")
        }
    }

    private var playingChip: some View {
        Text("PLAYING")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundColor(.pairtuneSecondary)
            .tracking(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.pairtuneSecondary.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.pairtuneSecondary.opacity(0.30), lineWidth: 0.5)
                    )
            )
    }

    // MARK: - Up next

    @ViewBuilder
    private var upNextSection: some View {
        sectionHeader(
            icon: "list.number",
            title: "次に再生",
            sub: "UP NEXT · \(roomViewModel.queue.items.count)",
            accent: .pairtunePrimary
        )

        if roomViewModel.queue.items.isEmpty {
            placeholderCard(text: "キューに曲がありません。「+ 追加」から曲を加えましょう。")
        } else {
            // List + onMove で並べ替え。背景透過してカスタム見た目を保つ。
            List {
                ForEach(Array(roomViewModel.queue.items.enumerated()), id: \.element.id) { idx, item in
                    queueRow(item: item, index: idx)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                }
                .onMove { from, to in
                    Task {
                        var newItems = roomViewModel.queue.items
                        newItems.move(fromOffsets: from, toOffset: to)
                        await roomViewModel.queue.reorder(newItems)
                    }
                }
                .onDelete { offsets in
                    Task {
                        for idx in offsets {
                            let item = roomViewModel.queue.items[idx]
                            await roomViewModel.queue.remove(itemId: item.id)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(roomViewModel.queue.items.count) * 64 + 8)
            .environment(\.editMode, .constant(.active))
        }
    }

    private func queueRow(item: QueueItem, index: Int) -> some View {
        // 行タップで再生、⋯ ボタンタップで context menu を出す。
        // 行全体を Button にすると ⋯ の Button タップが行 Button にも伝播して
        // 両方発火するため、行は Button、⋯ はその内側に置く(SwiftUI は内側 Button
        // のタップを優先的にハンドルし、外側 Button に伝播しない)。
        Button {
            Task { await roomViewModel.playFromQueue(item) }
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "7A7588"))
                    .frame(width: 18)
                    .monospacedDigit()

                artworkView(
                    url: item.artworkUrl,
                    size: 40,
                    accent: .pairtunePrimary,
                    stops: [
                        .init(color: .pairtunePrimary, location: 0),
                        .init(color: Color(hex: "4A1D3D"), location: 1),
                    ]
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.songTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(item.artistName)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "7A7588"))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                if let dur = item.durationSeconds {
                    Text(fmt(dur))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "5A5566"))
                        .monospacedDigit()
                }

                Button {
                    contextTrack = item.toTrack()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "5A5566"))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.025))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recently played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        sectionHeader(
            icon: "clock.arrow.circlepath",
            title: "最近の再生",
            sub: "RECENTLY PLAYED",
            accent: Color(hex: "7A7588")
        )
        VStack(spacing: 4) {
            ForEach(recentlyPlayed.prefix(8)) { entry in
                HStack(spacing: 10) {
                    artworkView(
                        url: entry.artworkUrl,
                        size: 36,
                        accent: Color(hex: "7A7588"),
                        stops: [
                            .init(color: Color(hex: "3A3548"), location: 0),
                            .init(color: Color(hex: "1F1A30"), location: 1),
                        ]
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.songTitle)
                            .font(.system(size: 12.5))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(entry.artistName)
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(hex: "7A7588"))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(relativeTime(entry.playedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "5A5566"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text(footerText)
            .font(.system(size: 10.5))
            .foregroundColor(Color(hex: "5A5566"))
            .multilineTextAlignment(.leading)
            .lineSpacing(3)
            .padding(.top, 8)
    }

    private var footerText: String {
        switch roomViewModel.mode {
        case .shared:
            return "どちらも追加・並び替え・削除ができます。最後の操作が優先されます。"
        case .solo:
            return "キューはこの再生セッション内でのみ有効です。"
        }
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String, sub: String, accent: Color) -> some View {
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
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.5)
            }
            Spacer()
        }
    }

    private func placeholderCard(text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Color(hex: "7A7588"))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    )
            )
    }

    @ViewBuilder
    private func artworkView(url: String?, size: CGFloat, accent: Color, stops: [Gradient.Stop]) -> some View {
        Group {
            if let urlStr = url, let u = URL(string: urlStr) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        LinearGradient(stops: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            } else {
                LinearGradient(stops: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        switch elapsed {
        case ..<30:        return "今"
        case ..<60:        return "\(elapsed) 秒前"
        case ..<3600:      return "\(elapsed / 60) 分前"
        case ..<86400:     return "\(elapsed / 3600) 時間前"
        default:           return "\(elapsed / 86400) 日前"
        }
    }
}
