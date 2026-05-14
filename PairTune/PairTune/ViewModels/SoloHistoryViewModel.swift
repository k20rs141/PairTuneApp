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
    /// 相手の最近のお気に入り(`is_favorited=TRUE` を `share_favorites=TRUE` の partner から取得)。
    /// `share_favorites=FALSE` の時は RLS で 0 件しか返らない。
    var partnerFavorites: [PlayHistoryEntry] = []
    private(set) var hasLoaded = false

    private let client = SupabaseManager.shared.client
    private let historyService = HistoryService()

    /// 「お気に入りに追加 / 解除」アクション。my_room_play_history の is_favorited を
    /// トグルする。楽観更新 + 失敗時ロールバック。
    func toggleFavorite(_ entry: PlayHistoryEntry, userId: String) async {
        guard let idx = myRecent.firstIndex(where: { $0.id == entry.id }) else { return }
        let previous = myRecent[idx].isFavorited ?? false
        let next = !previous
        myRecent[idx].isFavorited = next
        myRecent[idx].favoritedAt = next ? Date() : nil

        let ok = await historyService.toggleFavorite(
            entryId: entry.id,
            userId: userId,
            favorited: next
        )
        if !ok {
            myRecent[idx].isFavorited = previous
            myRecent[idx].favoritedAt = entry.favoritedAt
        }
    }

    /// 「履歴から削除」アクションのハンドラ。my_room_play_history のエントリを
    /// 楽観的に myRecent から取り除き、Supabase 側でも DELETE する。
    /// 失敗した時はロールバックして UI を元に戻す。
    func deleteMyRecent(_ entry: PlayHistoryEntry, userId: String) async {
        let prevIndex = myRecent.firstIndex(where: { $0.id == entry.id })
        if let i = prevIndex {
            myRecent.remove(at: i)
        }
        let ok = await historyService.deleteSoloPlay(entryId: entry.id, userId: userId)
        if !ok, let i = prevIndex {
            myRecent.insert(entry, at: min(i, myRecent.count))
        }
    }

    /// 相手のお気に入りを取得する。`share_favorites=FALSE` の partner には RLS で
    /// 0 件しか返らないので、UI 側で空ステートを出すことで OPT-IN の対応となる。
    func loadPartnerFavorites(partnerUserId: String?) async {
        guard let partnerUserId, !partnerUserId.isEmpty else {
            partnerFavorites = []
            return
        }
        partnerFavorites = await historyService.fetchPartnerFavorites(partnerUserId: partnerUserId)
    }

    /// pairId がある場合は shared_room 履歴も取得。常に自分の my_room 履歴を取得。
    /// partnerUserId が渡されたら相手のお気に入りも取得する。
    func load(pairId: String?, userId: String, partnerUserId: String? = nil) async {
        guard !userId.isEmpty else { return }
        if let pid = pairId {
            await loadSharedHistory(pairId: pid)
        }
        await loadMyRecent(userId: userId)
        await loadPartnerFavorites(partnerUserId: partnerUserId)
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
            // played_duration_seconds < 30 の行は Search からの「♥ 専用マーカー」なので除外。
            // 実プレイは recordSoloPlay の guard で必ず >=30s で INSERT される。
            myRecent = try await client
                .from("my_room_play_history")
                .select()
                .eq("user_id", value: userId)
                .gte("played_duration_seconds", value: 30)
                .order("played_at", ascending: false)
                .limit(10)
                .execute()
                .value
        } catch {
            print("[SoloHistoryViewModel] loadMyRecent error:", error)
        }
    }
}
