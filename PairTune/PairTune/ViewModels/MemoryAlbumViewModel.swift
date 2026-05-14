import Foundation
import Supabase

// MARK: - MemoryAlbumViewModel (v0.4 §2.9)
//
// `shared_room_play_history` と `pair_relationships` を集計して、Memory Album の
// タイムライン用アイテムを生成する。
//
// 集計内容(MVP):
//   - header: ペアリング日数 / 曲数 / 合計時間
//   - milestone: 1ヶ月 / 100日 / 1年 など、すでに通過した節目
//   - first: 一番最初に一緒に聴いた曲
//   - most: 一番聴いた曲(同一 song_id の最頻出)+ 再生回数
//   - first-play: pair で初めて聴いた曲 (is_first_play = TRUE、先頭から数件)
//
// 未実装:
//   - late (夜更かしセッション集計)
//   - streak (連続日数)

@Observable
@MainActor
final class MemoryAlbumViewModel {
    let partnerName: String?
    let pair: PairRelationship?

    var totalSongs: Int = 0
    var totalDurationSeconds: Int = 0
    var pairDays: Int = 0
    var items: [MemoryItem] = []
    var isLoading: Bool = false
    var loadError: String?

    private let client = SupabaseManager.shared.client
    private var loadTask: Task<Void, Never>?

    init(pair: PairRelationship?, partnerName: String?) {
        self.pair = pair
        self.partnerName = partnerName
    }

    func load() {
        guard let pair, !isLoading else { return }
        isLoading = true
        loadError = nil
        loadTask?.cancel()
        loadTask = Task { [pairId = pair.id, pairedAt = pair.pairedAt] in
            do {
                let rows: [PlayHistoryEntry] = try await client
                    .from("shared_room_play_history")
                    .select()
                    .eq("pair_id", value: pairId)
                    .order("played_at", ascending: true)
                    .limit(500)
                    .execute()
                    .value
                guard !Task.isCancelled else { return }

                // header 集計
                let distinctSongs = Set(rows.map { $0.songId })
                self.totalSongs = distinctSongs.count
                self.totalDurationSeconds = rows.reduce(0) { $0 + $1.playedDurationSeconds }
                let days = Calendar.current.dateComponents([.day], from: pairedAt, to: Date()).day ?? 0
                self.pairDays = max(0, days)

                self.items = Self.buildItems(rows: rows, pairedAt: pairedAt)
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                return
            } catch {
                print("[MemoryAlbumViewModel] load error:", error)
                self.loadError = "読み込みできません。リトライしてください"
                self.isLoading = false
            }
        }
    }

    // MARK: - Item builder

    private static func buildItems(rows: [PlayHistoryEntry], pairedAt: Date) -> [MemoryItem] {
        var result: [MemoryItem] = []
        let calendar = Calendar(identifier: .gregorian)
        let jaFormatter = DateFormatter()
        jaFormatter.locale = Locale(identifier: "ja_JP")
        jaFormatter.dateFormat = "yyyy年M月d日"

        // 1) milestone(節目): 経過した anniversary を新しい順
        let now = Date()
        let elapsed = calendar.dateComponents([.day], from: pairedAt, to: now).day ?? 0
        let candidates: [(days: Int, label: String)] = [
            (365, "ペアリング 1 年"),
            (200, "ペアリング 200 日"),
            (100, "ペアリング 100 日"),
            (30, "ペアリング 1 ヶ月"),
            (7, "ペアリング 1 週間"),
        ]
        if let m = candidates.first(where: { elapsed >= $0.days }) {
            let achievedAt = calendar.date(byAdding: .day, value: m.days, to: pairedAt) ?? pairedAt
            let distinctSongs = Set(rows.map { $0.songId }).count
            let totalSec = rows.reduce(0) { $0 + $1.playedDurationSeconds }
            result.append(MemoryItem(
                id: "milestone-\(m.days)",
                kind: .milestone,
                date: jaFormatter.string(from: achievedAt),
                title: m.label,
                detail: "\(distinctSongs) 曲 · \(formatDuration(totalSec))",
                artworkUrl: nil,
                count: nil,
                trackId: nil,
                entry: nil
            ))
        }

        // 2) first: 最初に一緒に聴いた曲
        if let first = rows.first {
            result.append(MemoryItem(
                id: "first-\(first.id)",
                kind: .first,
                date: jaFormatter.string(from: first.playedAt),
                title: "初めて一緒に聴いた曲",
                detail: "\(first.songTitle) · \(first.artistName)",
                artworkUrl: first.artworkUrl.flatMap(URL.init(string:)),
                count: nil,
                trackId: first.songId,
                entry: first
            ))
        }

        // 3) most: 最頻出 song
        let counts = rows.reduce(into: [String: Int]()) { $0[$1.songId, default: 0] += 1 }
        if let (topId, topCount) = counts.max(by: { $0.value < $1.value }), topCount >= 2,
           let sample = rows.last(where: { $0.songId == topId }) {
            jaFormatter.dateFormat = "yyyy年M月"
            result.append(MemoryItem(
                id: "most-\(topId)",
                kind: .most,
                date: jaFormatter.string(from: sample.playedAt),
                title: "一番聴いた曲",
                detail: "\(sample.songTitle) · \(sample.artistName)",
                artworkUrl: sample.artworkUrl.flatMap(URL.init(string:)),
                count: topCount,
                trackId: sample.songId,
                entry: sample
            ))
            jaFormatter.dateFormat = "yyyy年M月d日"
        }

        // 4) first-play: ペアで初めて聴いた曲(is_first_play = TRUE)を最大 3 件
        let firstPlays = rows
            .filter { $0.isFirstPlay == true }
            .filter { $0.id != rows.first?.id }   // (2) と重複しない
            .prefix(3)
        for fp in firstPlays {
            result.append(MemoryItem(
                id: "first-play-\(fp.id)",
                kind: .firstPlay,
                date: jaFormatter.string(from: fp.playedAt),
                title: "初めて聴いた曲",
                detail: "\(fp.songTitle) · \(fp.artistName)",
                artworkUrl: fp.artworkUrl.flatMap(URL.init(string:)),
                count: nil,
                trackId: fp.songId,
                entry: fp
            ))
        }

        return result
    }

    private static func formatDuration(_ totalSec: Int) -> String {
        let minutes = totalSec / 60
        if minutes >= 60 {
            return "\(minutes / 60) 時間 \(minutes % 60) 分"
        }
        return "\(minutes) 分"
    }
}

// MARK: - MemoryItem

enum MemoryItemKind {
    case milestone
    case first
    case most
    case firstPlay
    case late
    case streak
}

struct MemoryItem: Identifiable {
    let id: String
    let kind: MemoryItemKind
    let date: String
    let title: String
    let detail: String?
    let artworkUrl: URL?
    let count: Int?
    /// タップで再生する曲 ID(Apple Music)。nil なら再生不可(milestone 等)。
    let trackId: String?
    /// 元の履歴エントリ。タップで再生する時に PlayHistoryEntry.toTrack() 経由で
    /// Solo の再生フロー(onPlayTrack)に渡す。milestone など由来の無いカードは nil。
    let entry: PlayHistoryEntry?
}
