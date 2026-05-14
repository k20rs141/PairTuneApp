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

    /// 二重 INSERT チェック用の最小限の型。
    /// `select("id,song_id")` で取れる列だけを持つ。`PlayHistoryEntry` は
    /// non-optional な `song_title` などを持つため、ここで使うと decode が必ず失敗する。
    private struct SharedPlayIDOnly: Decodable {
        let id: String
        let songId: String
        enum CodingKeys: String, CodingKey {
            case id
            case songId = "song_id"
        }
    }

    // MARK: - Solo

    /// my_room_play_history に記録する。
    /// - 30秒未満はスキップ(誤タップ・スキップ除外)
    /// - 直近1件と song_id が同じならスキップ(リピート再生の水増し防止)
    func recordSoloPlay(_ track: Track, userId: String, duration: Int) async {
        guard duration >= 30 else { return }
        do {
            let recent: [SharedPlayIDOnly] = try await client
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

    // MARK: - Solo: delete

    /// my_room_play_history から自分の 1 エントリを削除する。
    /// RLS で user_id = auth.uid() の行のみ削除可能。
    /// 戻り値は成功した時 true。失敗時は false。
    func deleteSoloPlay(entryId: String, userId: String) async -> Bool {
        do {
            try await client
                .from("my_room_play_history")
                .delete()
                .eq("id", value: entryId)
                .eq("user_id", value: userId)
                .execute()
            return true
        } catch {
            print("[HistoryService] deleteSoloPlay error:", error)
            return false
        }
    }

    // MARK: - Shared (M5 で使用)

    /// shared_room_play_history に記録する。
    /// 両端末がほぼ同時に INSERT するため、同一 pair × song の直近 60 秒以内の記録が
    /// 既にある場合はスキップして二重登録を防ぐ。
    func recordSharedPlay(
        _ track: Track,
        duration: Int,
        pairId: String,
        sharedRoomId: String
    ) async {
        guard duration >= 30 else { return }
        do {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cutoff = iso.string(from: Date().addingTimeInterval(-60))

            let recent: [SharedPlayIDOnly] = try await client
                .from("shared_room_play_history")
                .select("id,song_id")
                .eq("pair_id", value: pairId)
                .eq("song_id", value: track.id)
                .gte("played_at", value: cutoff)
                .limit(1)
                .execute()
                .value
            if !recent.isEmpty { return }

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
