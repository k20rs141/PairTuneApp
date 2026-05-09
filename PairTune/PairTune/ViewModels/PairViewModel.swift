import Foundation
import Supabase

// MARK: - PairViewModel
//
// v0.4 ペアリング機能の状態管理 + Realtime 購読。
// 仕様: docs/PairTune_Specification_v0.4.md §6
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §6
//
// 役割:
//   - 受信側: 自分宛の pair_requests INSERT を listen → pendingRequest を立てて承認モーダル表示
//   - 送信側: requestPair() を呼び、相手の応答 (UPDATE) を listen → sendState を更新
//   - ペア状態: pair_relationships の INSERT/UPDATE を listen → activePair を更新 (state B 切替)
//
// Realtime 設計:
//   - postgres_changes でテーブル変更を購読し、変更通知をトリガに DB を再 SELECT する。
//     payload を直接デコードしない理由 = postgres timestamp フォーマットが
//     iso8601 と微妙に異なる場合があり、SELECT 経由の方が頑健。
//   - 1ユーザー1チャネル(`pair:<userId>`)。ContentView が session 立ち上がり時に start、
//     サインアウトで stop。

@Observable
@MainActor
final class PairViewModel {

    // MARK: - SendState

    enum SendState: Equatable {
        case idle
        case sending           // requestPair 実行中
        case waiting           // 申請 INSERT 成功、相手の応答待ち
        case accepted          // 承認された(state B に遷移)
        case rejected          // 拒否された
        case expired           // 24h 経過
        case error(String)

        var isTerminal: Bool {
            switch self {
            case .accepted, .rejected, .expired, .error: return true
            default: return false
            }
        }
    }

    // MARK: - State (UI が観察)

    /// 自分宛の pending 申請(承認モーダル表示用)
    var pendingRequest: PairRequest?
    /// pendingRequest の requester プロフィール(モーダルに表示)
    var pendingRequester: ProfileV4?

    /// 自分が送信した申請の現状態
    var sendState: SendState = .idle
    /// 直近の送信申請(あれば)
    var outgoingRequest: PairRequest?

    /// アクティブなペア(なければ state A)
    var activePair: PairRelationship?
    /// パートナーのプロフィール(activePair が立った時に lazy load)
    var partnerProfile: ProfileV4?

    // MARK: - Private

    private let pairService = PairService()
    private let client = SupabaseManager.shared.client

    private var meId: String?
    private var channel: RealtimeChannelV2?
    private var listenTasks: [Task<Void, Never>] = []

    // MARK: - Lifecycle

    /// session が立ち上がったら呼ぶ。冪等。
    /// - Note: `myUserId` は `UUID.uuidString`(大文字)で渡されるため lowercase に
    ///   正規化してから保持する。Postgres から返る UUID は小文字なので、
    ///   内部ではすべて小文字で扱うことで文字列比較のミスマッチを回避する。
    func start(myUserId: String) async {
        let normalized = myUserId.lowercased()
        if meId == normalized, channel != nil {
            // 同一ユーザーで既に接続済み: 念のため最新化だけ行う
            await refreshAll()
            return
        }
        await stop()
        meId = normalized
        await refreshAll()
        await subscribe(myUserId: normalized)
    }

    func stop() async {
        for task in listenTasks { task.cancel() }
        listenTasks = []
        if let ch = channel {
            // RealtimeChannelManager と同様、unsubscribe が返らないケースに備えタイムアウト
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await ch.unsubscribe() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        channel = nil
        meId = nil
        pendingRequest = nil
        pendingRequester = nil
        outgoingRequest = nil
        sendState = .idle
        activePair = nil
        partnerProfile = nil
    }

    // MARK: - Refresh

    func refreshAll() async {
        await refreshActivePair()
        await refreshPendingIncoming()
        await refreshOutgoing()
    }

    private func refreshActivePair() async {
        guard let meId else { return }
        do {
            let pair = try await pairService.fetchActivePair(userId: meId)
            activePair = pair
            if let pair, let partnerId = pair.partnerUserId(meId: meId) {
                partnerProfile = try? await pairService.fetchProfile(userId: partnerId)
            } else {
                partnerProfile = nil
                if pair != nil {
                    // ここに来たら `partnerUserId` の比較ロジックにバグ。
                    // (UUID 大小文字不一致は v0.4-M3 で修正済み)
                    print("[PairViewModel] WARNING: pair exists but partnerUserId(meId=\(meId)) returned nil; userA=\(pair!.userAId) userB=\(pair!.userBId)")
                }
            }
        } catch {
            print("[PairViewModel] refreshActivePair error:", error)
        }
    }

    private func refreshPendingIncoming() async {
        guard let meId else { return }
        do {
            let req = try await pairService.fetchPendingIncomingRequest(userId: meId)
            pendingRequest = req
            if let req {
                pendingRequester = try? await pairService.fetchProfile(userId: req.requesterId)
            } else {
                pendingRequester = nil
            }
        } catch {
            print("[PairViewModel] refreshPendingIncoming error:", error)
        }
    }

    private func refreshOutgoing() async {
        guard let meId else { return }
        do {
            let latest = try await pairService.fetchLatestOutgoingRequest(userId: meId)
            outgoingRequest = latest
            // 起動時の状態復元: 直近申請が pending かつ未失効なら waiting に戻す。
            // それ以外で sendState が .idle のままなら何もしない(過去の終了済み申請を蒸し返さない)。
            if sendState == .idle, let r = latest, r.status == .pending, !r.isExpired {
                sendState = .waiting
            }
        } catch {
            print("[PairViewModel] refreshOutgoing error:", error)
        }
    }

    // MARK: - Actions

    /// 申請送信。送信成功なら nil、失敗ならエラーメッセージを返す。
    /// - Note: sendState はこのメソッド内で `.sending` → `.waiting` / `.error` に遷移。
    func requestPair(targetCode: String) async -> String? {
        sendState = .sending
        do {
            let req = try await pairService.requestPair(targetCode: targetCode)
            outgoingRequest = req
            sendState = .waiting
            return nil
        } catch let err as PairError {
            let msg = err.errorDescription ?? "送信に失敗しました"
            sendState = .error(msg)
            return msg
        } catch {
            let msg = error.localizedDescription
            sendState = .error(msg)
            return msg
        }
    }

    func acceptIncoming() async {
        guard let req = pendingRequest else { return }
        do {
            _ = try await pairService.acceptRequest(req.id)
            pendingRequest = nil
            pendingRequester = nil
            await refreshActivePair()
        } catch {
            print("[PairViewModel] accept error:", error)
            // 失敗時はモーダルは閉じない(ユーザーが再試行できるように)
            // 期限切れ等は postgres_changes UPDATE で自然に消える
        }
    }

    func rejectIncoming() async {
        guard let req = pendingRequest else { return }
        do {
            try await pairService.rejectRequest(req.id)
            pendingRequest = nil
            pendingRequester = nil
        } catch {
            print("[PairViewModel] reject error:", error)
        }
    }

    /// 「あとで決める」: モーダルを閉じるだけ(DB は変更しない)。
    /// 次回 refreshPendingIncoming で再表示される。
    func dismissIncoming() {
        pendingRequest = nil
        pendingRequester = nil
    }

    /// 解消: end_pair_relationship() RPC を呼ぶ。成功なら true。
    func endActivePair(preserveMemories: Bool) async -> Bool {
        guard let pair = activePair else { return false }
        do {
            try await pairService.endPair(pairId: pair.id, preserveMemories: preserveMemories)
            activePair = nil
            partnerProfile = nil
            outgoingRequest = nil
            sendState = .idle
            return true
        } catch {
            print("[PairViewModel] endPair error:", error)
            return false
        }
    }

    /// 送信側のターミナル状態(accepted/rejected/expired/error)を確認後、ユーザーが
    /// バナー等を閉じた時に呼ぶ。
    func clearSendState() {
        if sendState.isTerminal {
            sendState = .idle
        }
    }

    // MARK: - Realtime subscription

    private func subscribe(myUserId: String) async {
        let ch = client.channel("pair:\(myUserId)")
        channel = ch

        // 受信側: 自分宛の新規申請 INSERT
        let reqInserts = ch.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "pair_requests",
            filter: "target_id=eq.\(myUserId)"
        )
        // 送信側: 自分が出した申請の status 更新(accepted/rejected/expired)
        let reqUpdatesOut = ch.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "pair_requests",
            filter: "requester_id=eq.\(myUserId)"
        )
        // ペア成立: pair_relationships への自分関連 INSERT
        // postgres_changes は OR フィルタ不可なので user_a_id / user_b_id を別購読
        let pairInsertsA = ch.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "pair_relationships",
            filter: "user_a_id=eq.\(myUserId)"
        )
        let pairInsertsB = ch.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "pair_relationships",
            filter: "user_b_id=eq.\(myUserId)"
        )
        // ペア解消: status 等の UPDATE
        let pairUpdatesA = ch.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "pair_relationships",
            filter: "user_a_id=eq.\(myUserId)"
        )
        let pairUpdatesB = ch.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "pair_relationships",
            filter: "user_b_id=eq.\(myUserId)"
        )

        do {
            try await ch.subscribeWithError()
        } catch {
            print("[PairViewModel] subscribe error:", error)
            return
        }

        listenTasks.append(Task { [weak self] in
            for await _ in reqInserts {
                await self?.refreshPendingIncoming()
            }
        })
        listenTasks.append(Task { [weak self] in
            for await _ in reqUpdatesOut {
                await self?.handleOutgoingUpdate()
            }
        })
        listenTasks.append(Task { [weak self] in
            for await _ in pairInsertsA { await self?.handlePairChange() }
        })
        listenTasks.append(Task { [weak self] in
            for await _ in pairInsertsB { await self?.handlePairChange() }
        })
        listenTasks.append(Task { [weak self] in
            for await _ in pairUpdatesA { await self?.handlePairChange() }
        })
        listenTasks.append(Task { [weak self] in
            for await _ in pairUpdatesB { await self?.handlePairChange() }
        })
    }

    private func handleOutgoingUpdate() async {
        await refreshOutgoing()
        guard let out = outgoingRequest else { return }
        switch out.status {
        case .accepted:
            sendState = .accepted
            await refreshActivePair()
        case .rejected:
            sendState = .rejected
        case .expired:
            sendState = .expired
        case .pending:
            if !out.isExpired { sendState = .waiting }
        }
    }

    private func handlePairChange() async {
        await refreshActivePair()
        // 解消イベント等で activePair が nil になった場合、送信側の状態も整える
        if activePair == nil, sendState == .accepted {
            sendState = .idle
        }
    }
}
