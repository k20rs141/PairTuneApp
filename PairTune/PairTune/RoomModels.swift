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

// =============================================================================
// MARK: - v0.4 Models (M1 で追加)
// =============================================================================
// 既存の Room / Profile は v0.2 仕様のまま温存し、v0.4 schema に対応する
// RoomV4 / ProfileV4 をここに追加する。M2 以降で徐々に置換していく。
//
// 配置理由:
//   - 既存コード(RoomService.fetchMyRoom 等)が `Room` を参照している
//   - 一気に書き換えるとビルドが壊れる
//   - M1 では「画面からは使わない」(実装ガイド §4.1)のでデータ型のみ追加
//
// DB スキーマ: docs/PairTune_DB_Schema.sql Section 1
// 仕様: docs/PairTune_Specification_v0.4.md §6, §7, §8

enum RoomType: String, Codable {
    case myRoom = "my_room"
    case sharedRoom = "shared_room"
}

/// v0.4 schema 完全準拠の Room モデル。`room_type` で my_room / shared_room を区別。
/// 同期再生の現在状態を Room レコード自体に持つため、遅延参加ゲストもここから初期状態を復元できる。
struct RoomV4: Codable, Identifiable {
    let id: String
    let roomType: RoomType

    // 現在再生中の曲(last-write-wins で更新される)
    var currentSongId: String?
    var currentSongTitle: String?
    var currentArtistName: String?
    var currentArtworkUrl: String?
    var currentSongDurationMs: Int?
    var isPlaying: Bool
    var playbackPositionMs: Int
    var hostTimestampMs: Int64?
    var lastActionBy: String?
    var lastActionAt: Date?

    /// my_room の参加コード(shared_room では nil)
    var pairingCode: String?

    let createdAt: Date
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case roomType = "room_type"
        case currentSongId = "current_song_id"
        case currentSongTitle = "current_song_title"
        case currentArtistName = "current_artist_name"
        case currentArtworkUrl = "current_artwork_url"
        case currentSongDurationMs = "current_song_duration_ms"
        case isPlaying = "is_playing"
        case playbackPositionMs = "playback_position_ms"
        case hostTimestampMs = "host_timestamp_ms"
        case lastActionBy = "last_action_by"
        case lastActionAt = "last_action_at"
        case pairingCode = "pairing_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// v0.4 schema 完全準拠の Profile モデル。
/// 旧 Profile から `apple_user_id`, `pairing_code`, `active_pair_id`, opt-in/notify
/// 系のフィールドが追加されている。
struct ProfileV4: Codable, Identifiable {
    let id: String
    var displayName: String
    var avatarUrl: String?
    var appleUserId: String?

    /// 6文字のペアリングコード(O/0/I/1 除外、ユーザーごとに固定)
    var pairingCode: String

    /// 現在アクティブなペアの ID(なければ nil)
    var activePairId: String?

    /// 自分のマイルームの ID
    var myRoomId: String?

    // ── 共有設定(opt-in)──
    /// マイルーム再生履歴をパートナーに見せるか(default: false)
    var sharePlayHistory: Bool
    /// お気に入り曲をパートナーに見せるか(default: true)
    var shareFavorites: Bool

    // ── 通知設定 ──
    /// 相手オンライン通知(default: false)
    var notifyPartnerOnline: Bool
    /// 節目イベント通知(default: true)
    var notifyMilestones: Bool

    let createdAt: Date
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case appleUserId = "apple_user_id"
        case pairingCode = "pairing_code"
        case activePairId = "active_pair_id"
        case myRoomId = "my_room_id"
        case sharePlayHistory = "share_play_history"
        case shareFavorites = "share_favorites"
        case notifyPartnerOnline = "notify_partner_online"
        case notifyMilestones = "notify_milestones"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// v0.4 では room_participants は presence ログ用で、`is_host` フラグも持つ。
/// shared_room では両者 is_host = TRUE になる(両者対等のホスト権限)。
struct RoomParticipantV4: Codable, Identifiable {
    let id: String
    let roomId: String
    let userId: String
    let joinedAt: Date
    var leftAt: Date?
    var isHost: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case userId = "user_id"
        case joinedAt = "joined_at"
        case leftAt = "left_at"
        case isHost = "is_host"
    }
}
