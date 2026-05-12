import SwiftUI

// M6: Solo モード詳細 UI — 「ふたりで聴いた曲」「自分が最近聴いた曲」セクション。
// RoomViewWrapper の .sheet(isPresented:) から呼び出される。
// 仕様: docs/PairTune_Specification_v0.4.md §7-3

struct SoloHistorySheetView: View {
    let viewModel: SoloHistoryViewModel
    let partnerName: String?
    let hasPair: Bool

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            if !viewModel.hasLoaded {
                loadingView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // ふたりで聴いた曲(ペアリング済みの場合のみ)
                        if hasPair {
                            historySection(
                                icon: "music.note.list",
                                title: "ふたりで聴いた曲",
                                entries: viewModel.sharedHistory,
                                emptyMessage: "まだ一緒に聴いた曲はありません"
                            )
                        }

                        // 自分が最近聴いた曲
                        historySection(
                            icon: "clock",
                            title: "あなたが最近聴いた曲",
                            entries: viewModel.myRecent,
                            emptyMessage: "まだ聴いた曲がありません"
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .presentationBackground(Color.pairtuneBase)
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            SpinnerView(color: .pairtunePrimary, size: 20)
            Text("読み込み中...")
                .font(.system(size: 13))
                .foregroundColor(.pairtuneTextTertiary)
        }
    }

    private func historySection(
        icon: String,
        title: String,
        entries: [PlayHistoryEntry],
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.pairtunePrimary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }

            if entries.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 13))
                    .foregroundColor(.pairtuneTextTertiary)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(entries) { entry in
                            HistoryTrackCard(entry: entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - HistoryTrackCard

private struct HistoryTrackCard: View {
    let entry: PlayHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
            Text(entry.songTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 86, alignment: .leading)
            Text(entry.artistName)
                .font(.system(size: 10))
                .foregroundColor(.pairtuneTextTertiary)
                .lineLimit(1)
                .frame(width: 86, alignment: .leading)
        }
        .frame(width: 86)
    }

    private var artwork: some View {
        AsyncImage(url: URL(string: entry.artworkUrl ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                placeholderArtwork
            }
        }
        .frame(width: 86, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.pairtuneSurfaceHi)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundColor(.pairtuneTextQuaternary)
            )
    }
}
