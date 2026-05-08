import Foundation

// MARK: - Play History Models (v0.4)
// 再生履歴(shared / my の2系統)を扱うモデル。
// DB スキーマ: docs/PairTune_DB_Schema.sql Section 3
// 仕様: docs/PairTune_Specification_v0.4.md §8
// M1 で配置。実際の利用は M4(HistoryService 実装)から。
//
// 2 テーブル(shared_room_play_history / my_room_play_history)を 1 つの構造体で
// 表現するため、片方にしか存在しないフィールドはすべて Optional にしている。

struct PlayHistoryEntry: Codable, Identifiable {
    let id: String

    // 共通: 曲情報
    let songId: String
    let songTitle: String
    let artistName: String
    let albumTitle: String?
    let artworkUrl: String?

    // 共通: 再生情報
    let playedAt: Date
    let playedDurationSeconds: Int

    // shared_room_play_history 固有
    var sharedRoomId: String?
    var pairId: String?
    var totalDurationSeconds: Int?
    var initiatedBy: String?
    /// このペアでこの曲を初めて聴いたか(`mark_first_play()` トリガが自動設定)
    var isFirstPlay: Bool?
    var sessionId: String?

    // my_room_play_history 固有
    var userId: String?
    var isFavorited: Bool?
    var favoritedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case songId = "song_id"
        case songTitle = "song_title"
        case artistName = "artist_name"
        case albumTitle = "album_title"
        case artworkUrl = "artwork_url"
        case playedAt = "played_at"
        case playedDurationSeconds = "played_duration_seconds"

        case sharedRoomId = "shared_room_id"
        case pairId = "pair_id"
        case totalDurationSeconds = "total_duration_seconds"
        case initiatedBy = "initiated_by"
        case isFirstPlay = "is_first_play"
        case sessionId = "session_id"

        case userId = "user_id"
        case isFavorited = "is_favorited"
        case favoritedAt = "favorited_at"
    }
}

// MARK: - PairMilestone (v1.2 で UI 化、M1 では型定義のみ)

/// 自動検出される節目イベント(ペアリング 30日 / 100日 / 1年 等)。
/// MVP では INSERT/SELECT は不要。v1.2 でマイルストーンバッジ UI 化時に使用。
/// DB スキーマ: docs/PairTune_DB_Schema.sql Section 4
struct PairMilestone: Codable, Identifiable {
    let id: String
    let pairId: String
    let milestoneType: String  // 'anniversary_30d' / 'anniversary_100d' / 'anniversary_1y' / 'songs_100' / etc.
    let achievedAt: Date
    var notifiedAt: Date?
    var acknowledgedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case pairId = "pair_id"
        case milestoneType = "milestone_type"
        case achievedAt = "achieved_at"
        case notifiedAt = "notified_at"
        case acknowledgedAt = "acknowledged_at"
    }
}
