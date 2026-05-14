import SwiftUI

// MARK: - QueueSheet (v0.4 §2.15 / screens-queue.jsx)
//
// Room 画面の再生コントロール列のキューボタンから開く bottom sheet。
// 3 セクション + footer hint card:
//   1. 再生中 (Now playing) — gradient カード + 波形アニメ + PLAYING chip
//   2. 次に再生 (Up next · N 曲) — drag handle / # / art / 曲 / 追加者 avatar / dur / ⋯
//   3. このセッションで聴いた曲 (Recently played) — art opacity .85 / 曲 / "今" 等
//
// design source: /tmp/pairtune-design-v3/music-app/project/screens-queue.jsx

struct QueueSheet: View {
    @Bindable var roomViewModel: RoomViewModel
    var recentlyPlayed: [PlayHistoryEntry] = []
    /// Shared モード時の partner.displayName(追加者アバターのフォールバックラベル用)
    var partnerName: String? = nil
    /// 自分の uuid(追加者アバター判定に使う、 me / partner)
    var myUserId: String = ""
    var onAddTap: () -> Void
    var onDismiss: () -> Void

    @State private var contextTrack: Track?

    private var isSolo: Bool { roomViewModel.mode == .solo }

    var body: some View {
        ZStack {
            // 背景グラデ: surface → base
            LinearGradient(
                colors: [Color.pairtuneSurface, Color.pairtuneBase],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                grabber
                header
                hairline
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        nowPlayingSection
                        upNextSection
                        recentlyPlayedSection
                        footerHint
                            .padding(.horizontal, 22)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                    }
                }
                .scrollIndicators(.hidden)
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

    // MARK: - Top

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.18))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("キュー")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(0.2)
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "7A7588"))
                    .tracking(0.3)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "A8A8A8"))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.05))
                            .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var subtitleText: String {
        if isSolo {
            return "あなたのキュー · solo"
        }
        return "ふたりのキュー · shared · 両方から操作できます"
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 0.5)
    }

    // MARK: - Section header

    private func sectionHeader(_ ja: String, _ en: String, action: (() -> Void)? = nil, actionLabel: String? = nil) -> some View {
        HStack(spacing: 0) {
            Text(ja)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .tracking(0.3)
            Text(" · \(en)")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "5A5566"))
                .tracking(0.6)
                .textCase(.uppercase)
            Spacer()
            if let action, let actionLabel {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text(actionLabel)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.pairtunePrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Now playing

    @ViewBuilder
    private var nowPlayingSection: some View {
        sectionHeader("再生中", "Now playing")
        if let track = roomViewModel.currentTrack {
            HStack(spacing: 12) {
                ZStack {
                    artworkView(
                        url: track.artworkURL?.absoluteString,
                        size: 48,
                        stops: track.gradientStops
                    )
                    // Dark overlay + animated waveform
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.30))
                        .frame(width: 48, height: 48)
                    WaveformBars()
                        .frame(width: 20, height: 14)
                }
                .shadow(color: .black.opacity(0.45), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "A8A8A8"))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("PLAYING")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.pairtunePrimary)
                    .tracking(0.6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.pairtunePrimary.opacity(0.11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                            )
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary.opacity(0.12), Color.pairtuneSecondary.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 16)
        } else {
            placeholderCard(text: "再生中の曲はありません")
                .padding(.horizontal, 18)
        }
    }

    // MARK: - Up next

    @ViewBuilder
    private var upNextSection: some View {
        sectionHeader(
            "次に再生",
            "Up next · \(roomViewModel.queue.items.count) 曲",
            action: onAddTap,
            actionLabel: "追加"
        )

        if roomViewModel.queue.items.isEmpty {
            VStack(spacing: 6) {
                Text("キューは空です")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "7A7588"))
                Text("検索から曲を追加してください")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "5A5566"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.pairtunePrimary.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    )
            )
            .padding(.horizontal, 18)
        } else {
            // List + onMove + EditMode.active で drag-to-reorder を有効化。
            // 背景は scrollContentBackground(.hidden) と listRowBackground(.clear) で
            // 完全に透明化してデザインを保つ。
            List {
                ForEach(roomViewModel.queue.items) { item in
                    let idx = roomViewModel.queue.items.firstIndex(where: { $0.id == item.id }) ?? 0
                    upNextRow(item: item, position: idx + 1)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowSeparator(.hidden)
                }
                .onMove { from, to in
                    var newItems = roomViewModel.queue.items
                    newItems.move(fromOffsets: from, toOffset: to)
                    Task { await roomViewModel.queue.reorder(newItems) }
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

    private func upNextRow(item: QueueItem, position: Int) -> some View {
        HStack(spacing: 11) {
            // Drag handle (visual only — drag-reorder は MVP では省略)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle()
                        .fill(Color(hex: "3F3F4A"))
                        .frame(width: 14, height: 1)
                }
            }

            Text("\(position)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: "5A5566"))
                .frame(width: 14, alignment: .trailing)
                .monospacedDigit()

            Button {
                Task { await roomViewModel.playFromQueue(item) }
            } label: {
                HStack(spacing: 11) {
                    artworkView(
                        url: item.artworkUrl,
                        size: 40,
                        stops: [
                            .init(color: .pairtunePrimary, location: 0),
                            .init(color: Color(hex: "4A1D3D"), location: 1),
                        ]
                    )
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.songTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(item.artistName)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "7A7588"))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !isSolo, let added = item.addedBy {
                        adderAvatar(addedBy: added)
                    }
                    if let dur = item.durationSeconds {
                        Text(fmt(dur))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Color(hex: "5A5566"))
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                contextTrack = item.toTrack()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "5A5566"))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func adderAvatar(addedBy: String) -> some View {
        let isMe = addedBy == myUserId
        let initials = isMe ? "YO" : initialsForPartner()
        let baseColor = isMe ? Color.pairtunePrimary : Color.pairtuneSecondary
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [baseColor, baseColor.opacity(0.66)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1))
            Text(initials)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Color(hex: "0A0612"))
        }
        .frame(width: 20, height: 20)
    }

    private func initialsForPartner() -> String {
        // partnerName の先頭 1 文字を取って大文字 2 文字風に
        guard let name = partnerName, let first = name.first else { return "PA" }
        let s = String(first).uppercased()
        return s + s
    }

    // MARK: - Recently played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        sectionHeader("このセッションで聴いた曲", "Recently played")
        if recentlyPlayed.isEmpty {
            Text("まだ何も再生していません")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "5A5566"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
        } else {
            VStack(spacing: 0) {
                ForEach(recentlyPlayed.prefix(8)) { entry in
                    Button {
                        // タップで再開: Track を組み立てて再生
                        Task { await roomViewModel.playAsHost(entry.toTrack()) }
                    } label: {
                        recentRow(entry)
                    }
                    .buttonStyle(.plain)
                    if entry.id != recentlyPlayed.prefix(8).last?.id {
                        Rectangle()
                            .fill(Color.white.opacity(0.04))
                            .frame(height: 0.5)
                            .padding(.leading, 67)
                    }
                }
            }
        }
    }

    private func recentRow(_ entry: PlayHistoryEntry) -> some View {
        HStack(spacing: 11) {
            artworkView(
                url: entry.artworkUrl,
                size: 38,
                stops: [
                    .init(color: Color(hex: "3A3548"), location: 0),
                    .init(color: Color(hex: "1F1A30"), location: 1),
                ]
            )
            .opacity(0.85)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.songTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(entry.artistName)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "7A7588"))
                    .lineLimit(1)
            }
            Spacer()
            Text(relativeTime(entry.playedAt))
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "5A5566"))
                .tracking(0.3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Footer hint

    private var footerHint: some View {
        Text(isSolo
            ? "キューはこの再生セッション内でのみ有効です。"
            : "どちらも追加・並び替え・削除ができます。最後の操作が優先されます。")
            .font(.system(size: 10.5))
            .foregroundColor(Color(hex: "7A7588"))
            .lineSpacing(3)
            .tracking(0.2)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                    )
            )
    }

    // MARK: - Helpers

    private func placeholderCard(text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Color(hex: "7A7588"))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    )
            )
    }

    @ViewBuilder
    private func artworkView(url: String?, size: CGFloat, stops: [Gradient.Stop]) -> some View {
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
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 8 : 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size > 40 ? 8 : 6, style: .continuous)
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

// MARK: - Animated waveform (4 bars)

private struct WaveformBars: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let barWidth: CGFloat = 2
                let spacing: CGFloat = 3
                let centerY = size.height / 2
                for i in 0..<4 {
                    let phase = Double(i) * 0.25
                    let rawHeight = sin(t * 4 + phase) * 0.5 + 0.5  // 0..1
                    let height = CGFloat(3 + rawHeight * 8)        // 3..11
                    let x = CGFloat(i) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(.white)
                    )
                }
            }
        }
    }
}
