import SwiftUI

// MARK: - MemoryAlbumView (v0.4 §2.9)
//
// 「ふたりの音楽史」のタイムライン。
// アンカー:
//   - Solo > 「ふたりで聴いた曲」 > 「もっと見る」
//   - Home > anniversary state からの MemoryCard (将来)
//   - 記念日 push 通知からの遷移 (将来)
//
// 集計データ: MemoryAlbumViewModel
// デザイン: screens-memory.jsx::MemoryAlbumScreen

struct MemoryAlbumView: View {
    @State var viewModel: MemoryAlbumViewModel
    /// カードタップ時の再生コールバック。caller(SoloModeView)が PlayHistoryEntry を受け取って
    /// Solo の再生フローに流す。milestone カード(entry が nil)は disabled になる。
    var onPlay: ((PlayHistoryEntry) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // ambient — 親の幅を超えるサイズの Circle を直接置くと ZStack の
            // intrinsic size が広がって横方向にあふれるため、Color.clear に
            // overlay → clipped で囲んで画面幅に固定する。
            Color.clear
                .overlay(alignment: .top) {
                    Circle()
                        .fill(Color.pairtunePrimary.opacity(0.12))
                        .frame(width: 520, height: 520)
                        .blur(radius: 60)
                        .offset(y: -260)
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                navBar
                ScrollView {
                    VStack(spacing: 0) {
                        heroCard
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                            .padding(.bottom, 6)

                        if viewModel.isLoading && viewModel.items.isEmpty {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.pairtuneTextSecondary)
                                .padding(.top, 40)
                        } else if viewModel.items.isEmpty {
                            emptyHint
                                .padding(.horizontal, 18)
                                .padding(.top, 24)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(viewModel.items) { item in
                                    Button {
                                        if let entry = item.entry { onPlay?(entry) }
                                    } label: {
                                        MemoryCardItem(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(item.entry == nil || onPlay == nil)
                                }
                                placeholderFooter
                                    .padding(.top, 2)
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 56)
                        }

                        if let err = viewModel.loadError {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundColor(.pairtuneSyncBad)
                                .padding(.top, 24)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            if viewModel.items.isEmpty { viewModel.load() }
        }
    }

    // MARK: - Nav bar

    private var navBar: some View {
        ZStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "A8A8A8"))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.05))
                                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                Spacer()
                Color.clear.frame(width: 38, height: 38)
            }
            VStack(spacing: 1) {
                Text("思い出")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(0.2)
                Text("MEMORY ALBUM")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Hero card

    private var heroCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.pairtunePrimary, .pairtuneSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                    .shadow(color: Color.pairtunePrimary.opacity(0.33), radius: 14, y: 4)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(headerDetail)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.pairtunePrimary.opacity(0.16), Color.pairtuneSecondary.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    private var headerTitle: String {
        if let name = viewModel.partnerName, !name.isEmpty {
            return "\(name) さんと \(viewModel.pairDays) 日"
        }
        return "ふたりで \(viewModel.pairDays) 日"
    }

    private var headerDetail: String {
        let durationStr: String
        let total = viewModel.totalDurationSeconds
        let minutes = total / 60
        if minutes >= 60 {
            durationStr = "\(minutes / 60) 時間 \(minutes % 60) 分"
        } else {
            durationStr = "\(minutes) 分"
        }
        return "合計 \(viewModel.totalSongs) 曲 · \(durationStr)"
    }

    // MARK: - Empty / footer

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Text("まだ思い出はありません")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
            Text("一緒に 30 秒以上聴いた曲が、ここに記録されます。")
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "7A7588"))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.pairtunePrimary.opacity(0.20), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                )
        )
    }

    private var placeholderFooter: some View {
        Text("これからも、聴くたびに増えていきます。")
            .font(.system(size: 10.5))
            .foregroundColor(Color(hex: "5A5566"))
            .tracking(0.3)
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    )
            )
    }
}

// MARK: - Memory card item

private struct MemoryCardItem: View {
    let item: MemoryItem

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(item.date)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "7A7588"))
                    .tracking(0.4)
                    .lineLimit(1)
                Text(item.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(0.2)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.detail ?? "")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "A8A8A8"))
                        .tracking(0.2)
                        .lineLimit(1)
                    if let count = item.count {
                        Text("· \(count) 回")
                            .font(.system(size: 11.5))
                            .foregroundColor(.pairtunePrimary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.entry != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "5A5566"))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var leading: some View {
        if let url = item.artworkUrl {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default: artworkPlaceholder
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.pairtunePrimary.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                    )
                Image(systemName: glyph)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.pairtunePrimary)
            }
            .frame(width: 54, height: 54)
        }
    }

    private var glyph: String {
        switch item.kind {
        case .milestone: return "sparkles"
        case .late: return "moon.stars"
        case .streak: return "flame"
        case .first: return "1.circle.fill"
        case .most: return "chart.bar.fill"
        case .firstPlay: return "star.fill"
        }
    }

    private var artworkPlaceholder: some View {
        LinearGradient(
            colors: [Color.pairtunePrimary.opacity(0.6), Color(hex: "1F1830")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
