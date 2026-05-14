import Foundation
import Supabase

// MARK: - QueueService (v0.4 §2.15)
//
// Shared モードの再生キュー(room_queue テーブル)に対する CRUD 経路。
// Solo モードは in-memory(QueueViewModel 内の配列)で完結するためここでは扱わない。

final class QueueService {
    private let client = SupabaseManager.shared.client

    // MARK: - Read

    /// 指定 room の現キューを position 昇順で取得する。
    /// RLS で pair 当事者(active)または my_room オーナーのみ取得可能。
    func fetchQueue(roomId: String) async throws -> [QueueItem] {
        try await client
            .from("room_queue")
            .select()
            .eq("room_id", value: roomId)
            .order("position", ascending: true)
            .execute()
            .value
    }

    // MARK: - Insert

    /// 末尾に 1 件追加する。position は現在の最大 + 1。
    /// 連続押下時の race は同じ position が発生する可能性があるが、
    /// next-fetch で position 昇順 + addedAt 順に解決される(MVP)。
    func enqueue(roomId: String, track: Track, addedBy: String) async throws -> QueueItem {
        // 末尾 position を解決
        let last: [QueueItem] = try await client
            .from("room_queue")
            .select()
            .eq("room_id", value: roomId)
            .order("position", ascending: false)
            .limit(1)
            .execute()
            .value
        let nextPosition = (last.first?.position ?? -1) + 1

        struct Insert: Encodable {
            let roomId: String
            let position: Int
            let songId: String
            let songTitle: String
            let artistName: String
            let albumTitle: String?
            let artworkUrl: String?
            let durationSeconds: Int?
            let addedBy: String
            enum CodingKeys: String, CodingKey {
                case roomId = "room_id"
                case position
                case songId = "song_id"
                case songTitle = "song_title"
                case artistName = "artist_name"
                case albumTitle = "album_title"
                case artworkUrl = "artwork_url"
                case durationSeconds = "duration_seconds"
                case addedBy = "added_by"
            }
        }
        let payload = Insert(
            roomId: roomId,
            position: nextPosition,
            songId: track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumTitle: track.album.isEmpty ? nil : track.album,
            artworkUrl: track.artworkURL?.absoluteString,
            durationSeconds: track.duration > 0 ? track.duration : nil,
            addedBy: addedBy
        )
        let inserted: [QueueItem] = try await client
            .from("room_queue")
            .insert(payload, returning: .representation)
            .select()
            .execute()
            .value
        guard let row = inserted.first else {
            throw NSError(domain: "QueueService", code: -1)
        }
        return row
    }

    /// 「次に再生」のため、現在 position の直後に挿入する。
    func insertNext(roomId: String, afterPosition: Int, track: Track, addedBy: String) async throws -> QueueItem {
        // afterPosition より大きい既存行を全て +1 シフト(last-write-wins、race は許容)
        try await client.rpc("shift_queue_positions", params: ShiftParams(
            pRoomId: roomId,
            pFromPosition: afterPosition + 1
        )).execute()

        struct Insert: Encodable {
            let roomId: String
            let position: Int
            let songId: String
            let songTitle: String
            let artistName: String
            let albumTitle: String?
            let artworkUrl: String?
            let durationSeconds: Int?
            let addedBy: String
            enum CodingKeys: String, CodingKey {
                case roomId = "room_id"
                case position
                case songId = "song_id"
                case songTitle = "song_title"
                case artistName = "artist_name"
                case albumTitle = "album_title"
                case artworkUrl = "artwork_url"
                case durationSeconds = "duration_seconds"
                case addedBy = "added_by"
            }
        }
        let payload = Insert(
            roomId: roomId,
            position: afterPosition + 1,
            songId: track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumTitle: track.album.isEmpty ? nil : track.album,
            artworkUrl: track.artworkURL?.absoluteString,
            durationSeconds: track.duration > 0 ? track.duration : nil,
            addedBy: addedBy
        )
        let inserted: [QueueItem] = try await client
            .from("room_queue")
            .insert(payload, returning: .representation)
            .select()
            .execute()
            .value
        guard let row = inserted.first else {
            throw NSError(domain: "QueueService", code: -1)
        }
        return row
    }

    // MARK: - Delete

    /// 1 件削除。position は詰めない(MVP、表示時に position 昇順で並べるだけ)。
    func remove(itemId: String) async throws {
        try await client
            .from("room_queue")
            .delete()
            .eq("id", value: itemId)
            .execute()
    }

    /// 指定 room のキューを全削除(セッション終了時など)。
    func clear(roomId: String) async throws {
        try await client
            .from("room_queue")
            .delete()
            .eq("room_id", value: roomId)
            .execute()
    }

    // MARK: - Reorder

    /// 並べ替え: items の position を「現在の並び順そのもの」で 0 始まりに再採番して
    /// 一括 UPDATE する。drag-drop 完了時のみ呼ぶ。
    func reorder(items: [QueueItem]) async throws {
        struct PositionUpdate: Encodable {
            let id: String
            let position: Int
        }
        for (idx, item) in items.enumerated() {
            try await client
                .from("room_queue")
                .update(["position": idx])
                .eq("id", value: item.id)
                .execute()
        }
    }

    // MARK: - RPC params

    private struct ShiftParams: Encodable {
        let pRoomId: String
        let pFromPosition: Int
        enum CodingKeys: String, CodingKey {
            case pRoomId       = "p_room_id"
            case pFromPosition = "p_from_position"
        }
    }
}
