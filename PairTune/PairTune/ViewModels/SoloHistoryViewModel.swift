import Foundation
import Supabase

// M6: Solo モード詳細 UI — 履歴セクションのデータ取得と管理。
// 仕様: docs/PairTune_Specification_v0.4.md §7-3 / §7-4
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §9.2

@Observable
@MainActor
final class SoloHistoryViewModel {
    var sharedHistory: [PlayHistoryEntry] = []
    var myRecent: [PlayHistoryEntry] = []
    private(set) var hasLoaded = false

    private let client = SupabaseManager.shared.client

    /// pairId がある場合は shared_room 履歴も取得。常に自分の my_room 履歴を取得。
    func load(pairId: String?, userId: String) async {
        guard !userId.isEmpty else { return }
        if let pid = pairId {
            await loadSharedHistory(pairId: pid)
        }
        await loadMyRecent(userId: userId)
        hasLoaded = true
    }

    private func loadSharedHistory(pairId: String) async {
        do {
            // 両端末からの二重 INSERT(同じ song を A/B 両側がほぼ同時に記録する race)を
            // 潰す目的で、(song_id, played_at の 1 分バケット) で重複排除する。
            // - dual-write は秒単位で発生するので同一バケットに落ちて 1 件にまとまる
            // - 別の日・別のセッションで同じ曲を再生した場合は別バケット → 別カードとして表示される
            let raw: [PlayHistoryEntry] = try await client
                .from("shared_room_play_history")
                .select()
                .eq("pair_id", value: pairId)
                .order("played_at", ascending: false)
                .limit(60)
                .execute()
                .value

            var seen = Set<String>()
            sharedHistory = raw.filter { entry in
                let minuteBucket = Int(entry.playedAt.timeIntervalSince1970 / 60)
                let key = "\(entry.songId)#\(minuteBucket)"
                return seen.insert(key).inserted
            }
            .prefix(20)
            .map { $0 }
        } catch {
            print("[SoloHistoryViewModel] loadSharedHistory error:", error)
        }
    }

    private func loadMyRecent(userId: String) async {
        do {
            myRecent = try await client
                .from("my_room_play_history")
                .select()
                .eq("user_id", value: userId)
                .order("played_at", ascending: false)
                .limit(10)
                .execute()
                .value
        } catch {
            print("[SoloHistoryViewModel] loadMyRecent error:", error)
        }
    }
}
