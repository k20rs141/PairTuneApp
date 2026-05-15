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

    /// 承認 → ペア成立後、Celebration UI を表示するか(`acceptIncoming` 成功時に true)
    /// `dismissApprovalSheet()` で false に戻して sheet を閉じる。
    var showingCelebration: Bool = false

    /// 自分が送信した申請の現状態
    var sendState: SendState = .idle
    /// 直近の送信申請(あれば)
    var outgoingRequest: PairRequest?

    /// アクティブなペア(なければ state A)
    var activePair: PairRelationship?
    /// パートナーのプロフィール(activePair が立った時に lazy load)
    var partnerProfile: ProfileV4?

    /// 自分が当事者の ended pair(直近 5 件まで)。Profile > Memories トグルで
    /// preserve_memories を後から変更する対象を解決するために保持する。
    var endedPairs: [PairRelationship] = []
    /// 直近 ended pair の preserve_memories(UI の表示・トグル初期値に使う)。
    /// nil = ended pair が無い。
    var latestEndedPreserveMemories: Bool? { endedPairs.first?.preserveMemories }
    /// preserve_memories トグルの DB 反映中フラグ
    var isUpdatingPreserveMemories: Bool = false

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
        showingCelebration = false
        outgoingRequest = nil
        sendState = .idle
        activePair = nil
        partnerProfile = nil
        endedPairs = []
        // 「あとで」で抑制した申請 ID もリセット(stop() = サインアウト等のため)
        deferredRequestIds = []
    }

    // MARK: - Refresh

    func refreshAll() async {
        await refreshActivePair()
        await refreshPendingIncoming()
        await refreshOutgoing()
        await refreshEndedPairs()
    }

    private func refreshEndedPairs() async {
        guard let meId else { return }
        do {
            endedPairs = try await pairService.fetchEndedPairs(userId: meId)
        } catch {
            print("[PairViewModel] refreshEndedPairs error:", error)
        }
    }

    /// 直近 ended pair の preserve_memories を切り替える。Profile > Memories トグルから呼ぶ。
    /// 楽観更新 → RPC → 失敗時ロールバック。
    func updateLatestEndedPairPreserveMemories(_ preserve: Bool) async -> Bool {
        guard let target = endedPairs.first else { return false }
        let previous = target.preserveMemories
        // 楽観更新: ローカルの endedPairs[0] を書き換え
        endedPairs[0].preserveMemories = preserve
        endedPairs[0].scheduledDeletionAt = preserve ? nil : (target.scheduledDeletionAt ?? Date().addingTimeInterval(60 * 60 * 24 * 90))
        isUpdatingPreserveMemories = true
        defer { isUpdatingPreserveMemories = false }
        do {
            try await pairService.updatePreserveMemories(pairId: target.id, preserve: preserve)
            return true
        } catch {
            print("[PairViewModel] updatePreserveMemories error:", error)
            // rollback
            endedPairs[0].preserveMemories = previous
            endedPairs[0].scheduledDeletionAt = target.scheduledDeletionAt
            return false
        }
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
            let deferred = loadDeferredIds()
            // 「あとで」で保留に入れた申請はモーダル表示せずスキップ
            if let req, deferred.contains(req.id) {
                pendingRequest = nil
                pendingRequester = nil
                return
            }
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
            await refreshActivePair()
            // sheet は閉じず、Celebration body に切り替える。
            // pendingRequest は finishCelebration() で nil 化されて sheet 閉じる。
            showingCelebration = true
        } catch {
            print("[PairViewModel] accept error:", error)
            // 失敗時はモーダルは閉じない(ユーザーが再試行できるように)
            // 期限切れ等は postgres_changes UPDATE で自然に消える
        }
    }

    /// Celebration の「ふたりの部屋を開く」タップ後の後処理。
    /// pendingRequest を nil 化することで sheet を閉じる。
    func finishCelebration() {
        showingCelebration = false
        pendingRequest = nil
        pendingRequester = nil
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

    /// 「あとで決める」: モーダルを閉じる + 該当 request.id を「このセッション中だけ」
    /// 抑制対象に追加する。アプリ再起動 / サインインし直すと in-memory state が
    /// リセットされるので、まだ pending な申請があれば再度表示される。
    /// 期限は DB 側の 24h 自動失効に委ねる。
    func dismissIncoming() {
        if let id = pendingRequest?.id {
            deferredRequestIds.insert(id)
        }
        pendingRequest = nil
        pendingRequester = nil
    }

    // MARK: - Deferred request (in-memory only)

    /// 「あとで」で閉じた pending request の id 集合。session スコープ(再起動でリセット)。
    private var deferredRequestIds: Set<String> = []

    private func loadDeferredIds() -> Set<String> {
        return deferredRequestIds
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
            // 解消した pair が endedPairs の先頭に来るように再取得
            await refreshEndedPairs()
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

    /// PairWaitingView の「申請を取り消す」用。
    /// `cancel_pair_request()` RPC で DB の status を 'cancelled' に更新し、
    /// その後ローカル state もクリアする(B 側はこれ以降この申請を承認できなくなる)。
    func cancelOutgoingRequest() async {
        guard case .waiting = sendState, let req = outgoingRequest else { return }
        do {
            try await pairService.cancelRequest(req.id)
        } catch {
            print("[PairViewModel] cancelOutgoingRequest error:", error)
            // DB 側で失敗しても UI 側はキャンセル扱いにする(24h で自動失効する)
        }
        sendState = .idle
        outgoingRequest = nil
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
        // 受信側: 自分宛の申請の status 変化 UPDATE
        // (A 側が cancel した時 / cron で expired になった時に承認モーダルを閉じるため)
        let reqUpdatesIn = ch.postgresChange(
            UpdateAction.self,
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
            #if DEBUG
            print("[PairViewModel] subscribed pair:\(myUserId)")
            #endif
        } catch {
            print("[PairViewModel] subscribe error:", error)
            return
        }

        listenTasks.append(Task { [weak self] in
            for await _ in reqInserts {
                #if DEBUG
                print("[PairViewModel] realtime: pair_requests INSERT received")
                #endif
                await self?.refreshPendingIncoming()
            }
        })
        listenTasks.append(Task { [weak self] in
            for await _ in reqUpdatesIn {
                #if DEBUG
                print("[PairViewModel] realtime: pair_requests UPDATE received (target=me)")
                #endif
                // A 側 cancel や cron expired を受け取ると pending では無くなるので
                // fetchPendingIncomingRequest は nil を返し → 承認モーダルが閉じる
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
        case .cancelled:
            // 自分で取り消した時の最終確認: ローカル state を idle に戻し、
            // outgoingRequest も nil 化(PairWaitingView の再表示を防ぐ)
            sendState = .idle
            outgoingRequest = nil
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
