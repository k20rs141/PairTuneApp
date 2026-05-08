import Foundation

// ⚠️ DEPRECATED: v0.2 マイルーム単独方式のモデル群。
// M1 で v0.4 仕様(マイルーム + ペアリング方式)に再構築予定。
// 詳細: docs/PairTune_Implementation_Guide_v0.4.md §2 / §4
// 主な変更点:
//   - Room: room_type {my_room, shared_room} 区別 / current_song_* 詳細 /
//           host_timestamp_ms / last_action_by/at / pairing_code に再編
//   - Profile: apple_user_id, pairing_code, active_pair_id,
//              share_play_history, share_favorites, notify_* を追加
//   - 新規モデル: PairRelationship, PairRequest, PlayHistoryEntry を Models/ に追加

// MARK: - Room

struct Room: Codable, Identifiable {
    let id: String
    let code: String
    let hostId: String
    var isActive: Bool
    var currentSongId: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case hostId = "host_id"
        case isActive = "is_active"
        case currentSongId = "current_song_id"
        case createdAt = "created_at"
    }
}

// MARK: - Profile

struct Profile: Codable, Identifiable {
    let id: String
    var displayName: String?
    var avatarUrl: String?
    var myRoomId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case myRoomId = "my_room_id"
    }
}

// MARK: - RoomParticipant

struct RoomParticipant: Codable, Identifiable {
    let id: String
    let roomId: String
    let userId: String
    let joinedAt: Date
    var leftAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case userId = "user_id"
        case joinedAt = "joined_at"
        case leftAt = "left_at"
    }
}

// MARK: - PresenceUser

struct PresenceUser: Codable, Identifiable, Equatable {
    var userId: String
    var role: String        // "host" | "guest"
    var displayName: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
        case displayName = "display_name"
    }
}
