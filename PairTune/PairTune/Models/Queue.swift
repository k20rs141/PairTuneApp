import Foundation
import SwiftUI

// MARK: - QueueItem (v0.4 §2.15)
//
// 再生キューの 1 件を表す。Shared モードでは Supabase の room_queue テーブル行と
// 1:1 対応。Solo モードでは in-memory 配列で同型を使う(id はクライアント生成 UUID)。

struct QueueItem: Codable, Identifiable, Equatable {
    let id: String
    let roomId: String?
    var position: Int

    // 曲情報
    let songId: String
    let songTitle: String
    let artistName: String
    let albumTitle: String?
    let artworkUrl: String?
    let durationSeconds: Int?

    // 追加情報
    let addedBy: String?
    let addedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case position
        case songId = "song_id"
        case songTitle = "song_title"
        case artistName = "artist_name"
        case albumTitle = "album_title"
        case artworkUrl = "artwork_url"
        case durationSeconds = "duration_seconds"
        case addedBy = "added_by"
        case addedAt = "added_at"
    }

    /// 再生用 Track に変換(QueueSheet からタップで再生する時に使う)。
    /// duration / artwork のフォールバックも持つ。
    func toTrack() -> Track {
        Track(
            id: songId,
            title: songTitle,
            artist: artistName,
            album: albumTitle ?? "",
            duration: durationSeconds ?? 0,
            gradientStops: [
                .init(color: .pairtunePrimary, location: 0.0),
                .init(color: Color(hex: "4A1D3D"), location: 1.0),
            ],
            dominant: .pairtunePrimary,
            artworkURL: artworkUrl.flatMap(URL.init(string:))
        )
    }

    /// Solo モードのローカルキュー用ファクトリ(roomId なし、UUID で id 生成)。
    static func localItem(from track: Track, position: Int, addedBy: String?) -> QueueItem {
        QueueItem(
            id: UUID().uuidString,
            roomId: nil,
            position: position,
            songId: track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumTitle: track.album.isEmpty ? nil : track.album,
            artworkUrl: track.artworkURL?.absoluteString,
            durationSeconds: track.duration > 0 ? track.duration : nil,
            addedBy: addedBy,
            addedAt: Date()
        )
    }
}
