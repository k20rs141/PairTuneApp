import Foundation

// MARK: - Pair Models (v0.4)
// 2人のペアリング関係性とその申請を表すモデル群。
// DB スキーマ: docs/PairTune_DB_Schema.sql Section 2
// 仕様: docs/PairTune_Specification_v0.4.md §6
// M1 で配置。実際の利用は M3(PairService 実装)から。

// MARK: - PairRelationship

/// 2人の関係性。`accept_pair_request()` RPC で生成され、shared_room と紐づく。
/// `user_a_id < user_b_id` の制約があるので、UUID の昇順で保存される。
struct PairRelationship: Codable, Identifiable {
    let id: String
    let userAId: String
    let userBId: String
    let sharedRoomId: String
    let pairedAt: Date
    var status: PairStatus
    var endedAt: Date?
    var endedBy: String?

    /// 解消時の選択。true = 90 日後も保持(default)、false = 90 日後に物理削除
    var preserveMemories: Bool
    /// `preserveMemories = false` の時のみ非 nil(NOW + 90 days)
    var scheduledDeletionAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userAId = "user_a_id"
        case userBId = "user_b_id"
        case sharedRoomId = "shared_room_id"
        case pairedAt = "paired_at"
        case status
        case endedAt = "ended_at"
        case endedBy = "ended_by"
        case preserveMemories = "preserve_memories"
        case scheduledDeletionAt = "scheduled_deletion_at"
    }

    /// 自分から見た相手の user_id を返す。ペアの当事者でない場合は nil。
    func partnerUserId(meId: String) -> String? {
        if userAId == meId { return userBId }
        if userBId == meId { return userAId }
        return nil
    }
}

enum PairStatus: String, Codable {
    case active
    case paused
    case ended
}

// MARK: - PairRequest

/// ペアリング申請。24 時間で自動失効(`expires_at` または pg_cron `expire_old_pair_requests`)。
struct PairRequest: Codable, Identifiable {
    let id: String
    let requesterId: String
    let targetId: String
    var status: PairRequestStatus
    let createdAt: Date
    var respondedAt: Date?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case targetId = "target_id"
        case status
        case createdAt = "created_at"
        case respondedAt = "responded_at"
        case expiresAt = "expires_at"
    }

    /// 受信時点で expires_at を過ぎていれば true。
    var isExpired: Bool {
        status == .expired || expiresAt < Date()
    }

    /// 残り時間(秒)。0 以下なら期限切れ。
    var remainingSeconds: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }
}

enum PairRequestStatus: String, Codable {
    case pending
    case accepted
    case rejected
    case expired
}
