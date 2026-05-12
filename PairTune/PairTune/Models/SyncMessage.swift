import Foundation

// MARK: - PlayState (両者が2秒間隔で送信 — M5: 両者対等ホスト)

struct PlayState: Codable {
    var songId: String
    var playbackTime: Double     // 秒
    var isPlaying: Bool
    var hostTimestampMs: Int64   // 送信時の Unix ミリ秒
    var actorUserId: String      // 送信者の userId (last-write-wins 判定用)
    var seq: Int

    enum CodingKeys: String, CodingKey {
        case songId = "song_id"
        case playbackTime = "playback_time"
        case isPlaying = "is_playing"
        case hostTimestampMs = "host_timestamp_ms"
        case actorUserId = "actor_user_id"
        case seq
    }
}

// MARK: - PlayEvent (play/pause/skip 時に即時送信)

struct PlayEvent: Codable {
    var type: PlayEventType
    var songId: String?
    var playbackTime: Double

    enum PlayEventType: String, Codable {
        case play, pause, skip
    }

    enum CodingKeys: String, CodingKey {
        case type
        case songId = "song_id"
        case playbackTime = "playback_time"
    }
}
