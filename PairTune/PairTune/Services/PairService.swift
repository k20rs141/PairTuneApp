import Foundation
import Supabase

// MARK: - PairError

enum PairError: LocalizedError {
    case codeNotFound
    case selfPair
    case alreadyPaired
    case partnerAlreadyPaired
    case requestNotFound
    case requestNotPending
    case expired
    case notAuthenticated
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .codeNotFound:        return "コードが正しくありません"
        case .selfPair:            return "あなた自身のコードです"
        case .alreadyPaired:       return "既にペアがあります。先にペアリングを解消してください"
        case .partnerAlreadyPaired:return "相手は既に他のペアと繋がっています"
        case .requestNotFound:     return "申請が見つかりません"
        case .requestNotPending:   return "この申請は既に応答済みです"
        case .expired:             return "申請の有効期限が切れています"
        case .notAuthenticated:    return "サインインが必要です"
        case .unknown(let err):    return err.localizedDescription
        }
    }
}

// MARK: - PairService
//
// v0.4 ペアリング機能の DB 操作レイヤ。
// 仕様: docs/PairTune_Specification_v0.4.md §6
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §6
// DB スキーマ: docs/PairTune_DB_Schema.sql Section 2 / 5

final class PairService {
    private let client = SupabaseManager.shared.client

    // MARK: - RPC param structs

    private struct AcceptParams: Encodable {
        let pRequestId: String
        enum CodingKeys: String, CodingKey { case pRequestId = "p_request_id" }
    }

    private struct EndPairParams: Encodable {
        let pPairId: String
        let pEndedBy: String
        let pPreserveMemories: Bool
        enum CodingKeys: String, CodingKey {
            case pPairId            = "p_pair_id"
            case pEndedBy           = "p_ended_by"
            case pPreserveMemories  = "p_preserve_memories"
        }
    }

    private struct RequestByCodeParams: Encodable {
        let pTargetCode: String
        enum CodingKeys: String, CodingKey { case pTargetCode = "p_target_code" }
    }

    private struct UpdatePreserveParams: Encodable {
        let pPairId: String
        let pPreserve: Bool
        enum CodingKeys: String, CodingKey {
            case pPairId   = "p_pair_id"
            case pPreserve = "p_preserve"
        }
    }

    private struct RejectUpdate: Encodable {
        let status: String
        let respondedAt: String
        enum CodingKeys: String, CodingKey {
            case status
            case respondedAt = "responded_at"
        }
    }

    // MARK: - Send (requester)

    /// 相手のコードでペアリング申請を作成する。
    ///
    /// `request_pair_by_code()` SECURITY DEFINER RPC を 1 トランザクションで実行する。
    /// クライアント側で `profiles` を pairing_code で SELECT しないのは、
    /// profiles SELECT ポリシーが「自分」「ペア相手」「自分宛 pending 申請の requester」
    /// のみ許可しており、未ペアリング状態では他人を引けないため。
    /// 検証(自分が active ペア中 / 相手が active ペア中 / セルフペア / コード不在)は
    /// 全て RPC 内で行い、`RAISE EXCEPTION 'CODE_NOT_FOUND' …` 等の文字列で識別する。
    func requestPair(targetCode: String) async throws -> PairRequest {
        let normalized = targetCode.uppercased()
        do {
            let req: PairRequest = try await client
                .rpc("request_pair_by_code",
                     params: RequestByCodeParams(pTargetCode: normalized))
                .execute()
                .value
            return req
        } catch {
            throw mapRequestPairError(error)
        }
    }

    /// PostgreSQL `RAISE EXCEPTION` のメッセージから PairError へマッピング。
    /// supabase-swift は `PostgrestError` で message を運んでくる。
    private func mapRequestPairError(_ error: Error) -> PairError {
        let msg = String(describing: error).uppercased()
        if msg.contains("PARTNER_ALREADY_PAIRED")     { return .partnerAlreadyPaired }
        if msg.contains("ALREADY_PAIRED")             { return .alreadyPaired }
        if msg.contains("SELF_PAIR")                  { return .selfPair }
        if msg.contains("CODE_NOT_FOUND")             { return .codeNotFound }
        if msg.contains("NOT_AUTHENTICATED")          { return .notAuthenticated }
        return .unknown(error)
    }

    // MARK: - Approve / Reject (target)

    /// 申請を承認 → `accept_pair_request()` RPC が shared_room と pair_relationships を生成。
    /// - Returns: 生成された pair_id (UUID 文字列)
    @discardableResult
    func acceptRequest(_ requestId: String) async throws -> String {
        do {
            let pairId: String = try await client
                .rpc("accept_pair_request", params: AcceptParams(pRequestId: requestId))
                .execute()
                .value
            return pairId
        } catch {
            throw PairError.unknown(error)
        }
    }

    /// 申請者(A 側)から申請を取消(status='cancelled', responded_at=NOW)。
    /// `cancel_pair_request()` SECURITY DEFINER RPC を経由する(RLS 上 A 側は通常 UPDATE できないため)。
    /// 取消後は B 側の `accept_pair_request()` が `status != 'pending'` で弾かれる。
    /// migrations/0005_cancel_pair_request.sql を先に適用しておくこと。
    func cancelRequest(_ requestId: String) async throws {
        struct Params: Encodable {
            let pRequestId: String
            enum CodingKeys: String, CodingKey { case pRequestId = "p_request_id" }
        }
        do {
            try await client
                .rpc("cancel_pair_request", params: Params(pRequestId: requestId))
                .execute()
        } catch {
            throw PairError.unknown(error)
        }
    }

    /// 申請を拒否(status='rejected', responded_at=NOW)。
    func rejectRequest(_ requestId: String) async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try await client
            .from("pair_requests")
            .update(RejectUpdate(status: "rejected", respondedAt: iso.string(from: Date())))
            .eq("id", value: requestId)
            .execute()
    }

    // MARK: - End pair

    /// `end_pair_relationship()` RPC でペアリング解消。
    /// - Parameter preserveMemories: true で履歴閲覧専用モード、false で 90 日後物理削除。
    func endPair(pairId: String, preserveMemories: Bool) async throws {
        guard let meUUID = try? await client.auth.session.user.id else {
            throw PairError.notAuthenticated
        }
        do {
            try await client
                .rpc("end_pair_relationship", params: EndPairParams(
                    pPairId: pairId,
                    pEndedBy: meUUID.uuidString,
                    pPreserveMemories: preserveMemories
                ))
                .execute()
        } catch {
            throw PairError.unknown(error)
        }
    }

    /// 解消済み(status='ended')pair に対して preserve_memories を変更する。
    /// migration 0007 で追加した `update_preserve_memories(p_pair_id, p_preserve)` RPC を呼ぶ。
    /// - true  : scheduled_deletion_at を NULL にして永続保持
    /// - false : 既に値があれば維持、無ければ NOW()+90d を設定して 90 日後削除
    func updatePreserveMemories(pairId: String, preserve: Bool) async throws {
        do {
            try await client
                .rpc("update_preserve_memories", params: UpdatePreserveParams(
                    pPairId: pairId,
                    pPreserve: preserve
                ))
                .execute()
        } catch {
            throw PairError.unknown(error)
        }
    }

    /// 解消済みの自分の pair を最新順に取得。Profile > Memories トグルや
    /// Solo memory モードの遷移先候補として使う。limit で件数を絞る。
    func fetchEndedPairs(userId: String, limit: Int = 5) async throws -> [PairRelationship] {
        let rows: [PairRelationship] = try await client
            .from("pair_relationships")
            .select()
            .eq("status", value: "ended")
            .or("user_a_id.eq.\(userId),user_b_id.eq.\(userId)")
            .order("ended_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    // MARK: - Fetch helpers

    /// 任意ユーザーのプロフィール取得。
    /// - 自分自身、ペアリング相手、または自分宛 pending 申請の requester に対して RLS が許可。
    func fetchProfile(userId: String) async throws -> ProfileV4 {
        let profiles: [ProfileV4] = try await client
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .limit(1)
            .execute()
            .value
        guard let profile = profiles.first else { throw PairError.requestNotFound }
        return profile
    }

    /// 自分宛の pending 申請(期限未切れの直近 1 件)。アプリ起動時の初期 fetch 用。
    func fetchPendingIncomingRequest(userId: String) async throws -> PairRequest? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = iso.string(from: Date())
        let reqs: [PairRequest] = try await client
            .from("pair_requests")
            .select()
            .eq("target_id", value: userId)
            .eq("status", value: "pending")
            .gt("expires_at", value: now)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return reqs.first
    }

    /// 自分が送信した直近の申請(状態問わず)。送信後の状態変化追跡用。
    func fetchLatestOutgoingRequest(userId: String) async throws -> PairRequest? {
        let reqs: [PairRequest] = try await client
            .from("pair_requests")
            .select()
            .eq("requester_id", value: userId)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return reqs.first
    }

    /// 自分のアクティブペア。`profiles.active_pair_id` 経由で 1 回の SELECT で取得。
    func fetchActivePair(userId: String) async throws -> PairRelationship? {
        let profile = try await fetchProfile(userId: userId)
        guard let pairId = profile.activePairId else { return nil }
        let pairs: [PairRelationship] = try await client
            .from("pair_relationships")
            .select()
            .eq("id", value: pairId)
            .limit(1)
            .execute()
            .value
        return pairs.first
    }
}
