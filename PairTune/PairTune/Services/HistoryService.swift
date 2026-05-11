import Foundation
import Supabase

// M4: Solo モード用再生履歴記録サービス。
// 仕様: docs/PairTune_Specification_v0.4.md §7-4
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §7.2

final class HistoryService {
    private let client = SupabaseManager.shared.client

    // MARK: - Insert payload structs

    private struct SoloPlayInsert: Encodable {
        let userId: String
        let songId: String
        let songTitle: String
        let artistName: String
        let albumTitle: String?
        let artworkUrl: String?
        let playedDurationSeconds: Int

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case songId = "song_id"
            case songTitle = "song_title"
            case artistName = "artist_name"
            case albumTitle = "album_title"
            case artworkUrl = "artwork_url"
            case playedDurationSeconds = "played_duration_seconds"
        }
    }

    private struct SharedPlayInsert: Encodable {
        let sharedRoomId: String
        let pairId: String
        let songId: String
        let songTitle: String
        let artistName: String
        let albumTitle: String?
        let artworkUrl: String?
        let playedDurationSeconds: Int

        enum CodingKeys: String, CodingKey {
            case sharedRoomId = "shared_room_id"
            case pairId = "pair_id"
            case songId = "song_id"
            case songTitle = "song_title"
            case artistName = "artist_name"
            case albumTitle = "album_title"
            case artworkUrl = "artwork_url"
            case playedDurationSeconds = "played_duration_seconds"
        }
    }

    // MARK: - Solo

    /// my_room_play_history に記録する。
    /// - 30秒未満はスキップ(誤タップ・スキップ除外)
    /// - 直近1件と song_id が同じならスキップ(リピート再生の水増し防止)
    func recordSoloPlay(_ track: Track, userId: String, duration: Int) async {
        guard duration >= 30 else { return }
        do {
            let recent: [PlayHistoryEntry] = try await client
                .from("my_room_play_history")
                .select("id,song_id")
                .eq("user_id", value: userId)
                .order("played_at", ascending: false)
                .limit(1)
                .execute()
                .value
            if recent.first?.songId == track.id { return }

            let payload = SoloPlayInsert(
                userId: userId,
                songId: track.id,
                songTitle: track.title,
                artistName: track.artist,
                albumTitle: track.album.isEmpty ? nil : track.album,
                artworkUrl: track.artworkURL?.absoluteString,
                playedDurationSeconds: duration
            )
            try await client
                .from("my_room_play_history")
                .insert(payload)
                .execute()
        } catch {
            print("[HistoryService] recordSoloPlay error:", error)
        }
    }

    // MARK: - Shared (M5 で使用)

    /// shared_room_play_history に記録する。
    func recordSharedPlay(
        _ track: Track,
        duration: Int,
        pairId: String,
        sharedRoomId: String
    ) async {
        guard duration >= 30 else { return }
        do {
            let payload = SharedPlayInsert(
                sharedRoomId: sharedRoomId,
                pairId: pairId,
                songId: track.id,
                songTitle: track.title,
                artistName: track.artist,
                albumTitle: track.album.isEmpty ? nil : track.album,
                artworkUrl: track.artworkURL?.absoluteString,
                playedDurationSeconds: duration
            )
            try await client
                .from("shared_room_play_history")
                .insert(payload)
                .execute()
        } catch {
            print("[HistoryService] recordSharedPlay error:", error)
        }
    }
}
