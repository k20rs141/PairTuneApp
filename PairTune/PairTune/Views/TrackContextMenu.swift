import SwiftUI

// MARK: - TrackContextMenu (v0.4 §2.14)
//
// 長押しまたは ⋯ ボタンで表示される iOS 風 action sheet。
// グラスカード 3 枚(track preview / actions / cancel)+ slide-up.
//
// Apple `confirmationDialog` ではなく自前のオーバーレイで描く理由:
// - グラデーション・glass・track preview カードなどデザインで必要
// - 各アクションのアイコン chip を表現するため

struct TrackContextMenu: View {
    let track: Track
    /// shared モードで partner がいる時のみ「相手に送る」を表示。
    let partnerName: String?
    var onClose: () -> Void
    var onFavorite: () -> Void = {}
    var onSendToPartner: () -> Void = {}
    var onPlayNext: () -> Void = {}
    var onShowAlbum: (() -> Void)? = nil
    var onShowArtist: (() -> Void)? = nil
    var onRemoveFromHistory: (() -> Void)? = nil

    @State private var offsetY: CGFloat = 60
    @State private var bgOpacity: Double = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // dim background
            Color.black.opacity(0.55)
                .opacity(bgOpacity)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 8) {
                trackCard
                actionsCard
                cancelButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 28)
            .offset(y: offsetY)
        }
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                offsetY = 0
                bgOpacity = 1
            }
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) {
            offsetY = 80
            bgOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onClose() }
    }

    // MARK: - Track card

    private var trackCard: some View {
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
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "A8A8A8"))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(glassBackground)
    }

    // MARK: - Actions card

    private var actionsCard: some View {
        VStack(spacing: 0) {
            actionRow(
                icon: "sparkles",
                label: "お気に入りに追加",
                sub: "Add to favorites",
                accent: .pairtunePrimary,
                action: { onFavorite(); dismiss() }
            )
            if let partnerName, !partnerName.isEmpty {
                hairline
                actionRow(
                    icon: "paperplane.fill",
                    label: "\(partnerName) さんに送る",
                    sub: "Send to partner",
                    accent: .pairtuneSecondary,
                    action: { onSendToPartner(); dismiss() }
                )
            }
            hairline
            actionRow(
                icon: "text.line.first.and.arrowtriangle.forward",
                label: "次に再生",
                sub: "Play next",
                accent: nil,
                action: { onPlayNext(); dismiss() }
            )
            if let onShowAlbum {
                hairline
                actionRow(
                    icon: "square.stack",
                    label: "アルバムを見る",
                    sub: "Go to album",
                    accent: nil,
                    action: { onShowAlbum(); dismiss() }
                )
            }
            if let onShowArtist {
                hairline
                actionRow(
                    icon: "person.fill",
                    label: "アーティストを見る",
                    sub: "Go to artist",
                    accent: nil,
                    action: { onShowArtist(); dismiss() }
                )
            }
            if let onRemoveFromHistory {
                hairline
                actionRow(
                    icon: "xmark",
                    label: "履歴から削除",
                    sub: "Remove from history",
                    accent: nil,
                    danger: true,
                    action: { onRemoveFromHistory(); dismiss() }
                )
            }
        }
        .background(glassBackground)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    private func actionRow(
        icon: String,
        label: String,
        sub: String,
        accent: Color?,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconBackground(accent: accent, danger: danger))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(iconBorder(accent: accent, danger: danger), lineWidth: 0.5)
                        )
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(iconTint(accent: accent, danger: danger))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(danger ? Color(hex: "E85B6B") : .white)
                        .tracking(0.2)
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "5A5566"))
                        .tracking(0.2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconBackground(accent: Color?, danger: Bool) -> Color {
        if danger { return Color(hex: "E85B6B").opacity(0.12) }
        if let accent { return accent.opacity(0.11) }
        return Color.white.opacity(0.05)
    }

    private func iconBorder(accent: Color?, danger: Bool) -> Color {
        if danger { return Color(hex: "E85B6B").opacity(0.25) }
        if let accent { return accent.opacity(0.30) }
        return Color.white.opacity(0.06)
    }

    private func iconTint(accent: Color?, danger: Bool) -> Color {
        if danger { return Color(hex: "E85B6B") }
        return accent ?? Color(hex: "A8A8A8")
    }

    // MARK: - Cancel

    private var cancelButton: some View {
        Button(action: dismiss) {
            Text("キャンセル")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(glassBackground)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Glass

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(hex: "141020").opacity(0.92))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: -10)
    }
}

// MARK: - Modifier helper

extension View {
    /// `.sheet` を使わず ZStack で TrackContextMenu を重ねたい時に使うヘルパー。
    func trackContextMenu(item: Binding<Track?>, partnerName: String?,
                          onFavorite: @escaping (Track) -> Void = { _ in },
                          onSendToPartner: @escaping (Track) -> Void = { _ in },
                          onPlayNext: @escaping (Track) -> Void = { _ in },
                          onShowAlbum: ((Track) -> Void)? = nil,
                          onShowArtist: ((Track) -> Void)? = nil,
                          onRemoveFromHistory: ((Track) -> Void)? = nil) -> some View {
        ZStack {
            self
            if let track = item.wrappedValue {
                TrackContextMenu(
                    track: track,
                    partnerName: partnerName,
                    onClose: { item.wrappedValue = nil },
                    onFavorite: { onFavorite(track) },
                    onSendToPartner: { onSendToPartner(track) },
                    onPlayNext: { onPlayNext(track) },
                    onShowAlbum: onShowAlbum.map { fn in { fn(track) } },
                    onShowArtist: onShowArtist.map { fn in { fn(track) } },
                    onRemoveFromHistory: onRemoveFromHistory.map { fn in { fn(track) } }
                )
                .transition(.opacity)
            }
        }
    }
}
