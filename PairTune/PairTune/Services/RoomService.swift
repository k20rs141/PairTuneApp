import Foundation
import Supabase

// v0.2 (Beside) → v0.4 (PairTune) 移行中。
// M2 で v0.4 用 API (fetchMyProfile / fetchMyRoomV4 / updateAppleUserId) を追加。
// 旧 v0.2 API (fetchMyRoom / joinRoom) は @available(deprecated) でマーキングし、
// 既存呼び出し元のコンパイル維持のためスタブだけ残す(v0.4 schema 適用後は実行不可)。
// 詳細: docs/PairTune_Implementation_Guide_v0.4.md §2 / §5 / §6

enum RoomError: LocalizedError {
    case notFound
    case notAuthenticated
    case ownRoom
    case schemaIncompatible    // v0.2 API を v0.4 schema に対して呼んだ時
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "コードが正しくありません"
        case .notAuthenticated:
            return "サインインが必要です"
        case .ownRoom:
            return "これはあなた自身のルームです"
        case .schemaIncompatible:
            return "このフローは v0.4 で廃止されました"
        case .unknown(let err):
            return err.localizedDescription
        }
    }
}

final class RoomService {
    private let client = SupabaseManager.shared.client

    // =========================================================================
    // MARK: - v0.4 API
    // =========================================================================

    /// 自分のプロフィール(v0.4 schema)。サインイン直後に取得して `AuthViewModel` が保持する。
    func fetchMyProfile() async throws -> ProfileV4 {
        guard let userId = try? await client.auth.session.user.id else {
            throw RoomError.notAuthenticated
        }
        let profiles: [ProfileV4] = try await client
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
        guard let profile = profiles.first else {
            throw RoomError.notFound
        }
        return profile
    }

    /// shared_room を ID で取得(M5 Shared モード参加時に使う)。
    func fetchSharedRoom(roomId: String) async throws -> RoomV4 {
        let rooms: [RoomV4] = try await client
            .from("rooms")
            .select()
            .eq("id", value: roomId)
            .limit(1)
            .execute()
            .value
        guard let room = rooms.first else {
            throw RoomError.notFound
        }
        return room
    }

    /// 自分のマイルーム(v0.4 schema、`room_type = 'my_room'`)。
    /// `handle_new_user()` トリガで profile 作成時に my_room も自動生成済み。
    func fetchMyRoomV4() async throws -> RoomV4 {
        let profile = try await fetchMyProfile()
        guard let myRoomId = profile.myRoomId else {
            throw RoomError.notFound
        }
        let rooms: [RoomV4] = try await client
            .from("rooms")
            .select()
            .eq("id", value: myRoomId)
            .limit(1)
            .execute()
            .value
        guard let room = rooms.first else {
            throw RoomError.notFound
        }
        return room
    }

    /// プロフィール画像を Supabase Storage(`avatars` バケット)にアップロードし、
    /// その公開 URL を `profiles.avatar_url` に反映する。
    /// パス: `avatars/<user_uuid>/avatar.jpg`(upsert)。
    /// migrations/0004_avatars_storage.sql を先に適用しておくこと。
    func uploadAvatar(jpegData: Data) async throws -> String {
        guard let userId = try? await client.auth.session.user.id else {
            throw RoomError.notAuthenticated
        }
        let path = "\(userId.uuidString.lowercased())/avatar.jpg"
        let bucket = client.storage.from("avatars")
        // upsert で同じパスに上書き(古い画像の削除は不要)
        _ = try await bucket.upload(
            path,
            data: jpegData,
            options: FileOptions(contentType: "image/jpeg", upsert: true)
        )
        let publicURL = try bucket.getPublicURL(path: path)
        // cache busting: 同一 URL でも画像が変わったことを下流に伝えるため query を付与
        let urlWithCacheBust = publicURL.absoluteString + "?t=\(Int(Date().timeIntervalSince1970))"
        try await client
            .from("profiles")
            .update(["avatar_url": urlWithCacheBust])
            .eq("id", value: userId.uuidString)
            .execute()
        return urlWithCacheBust
    }

    /// 表示名を更新(プロフィール編集)。
    func updateDisplayName(_ displayName: String) async throws {
        guard let userId = try? await client.auth.session.user.id else {
            throw RoomError.notAuthenticated
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await client
            .from("profiles")
            .update(["display_name": trimmed])
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// 通知設定を更新(M6: notify_partner_online / notify_milestones)。
    func updateNotificationSettings(notifyPartnerOnline: Bool, notifyMilestones: Bool) async throws {
        guard let userId = try? await client.auth.session.user.id else {
            throw RoomError.notAuthenticated
        }
        struct NotifyUpdate: Encodable {
            let notifyPartnerOnline: Bool
            let notifyMilestones: Bool
            enum CodingKeys: String, CodingKey {
                case notifyPartnerOnline = "notify_partner_online"
                case notifyMilestones    = "notify_milestones"
            }
        }
        try await client
            .from("profiles")
            .update(NotifyUpdate(notifyPartnerOnline: notifyPartnerOnline, notifyMilestones: notifyMilestones))
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// プライバシー設定を保存する(M6: share_play_history / share_favorites)。
    func updatePrivacySettings(sharePlayHistory: Bool, shareFavorites: Bool) async throws {
        guard let userId = try? await client.auth.session.user.id else {
            throw RoomError.notAuthenticated
        }

        struct PrivacyUpdate: Encodable {
            let sharePlayHistory: Bool
            let shareFavorites: Bool
            enum CodingKeys: String, CodingKey {
                case sharePlayHistory = "share_play_history"
                case shareFavorites   = "share_favorites"
            }
        }

        try await client
            .from("profiles")
            .update(PrivacyUpdate(sharePlayHistory: sharePlayHistory, shareFavorites: shareFavorites))
            .eq("id", value: userId.uuidString)
            .execute()
    }

    /// Apple Sign In の `credential.user`(安定識別子)を `profiles.apple_user_id` に保存。
    /// 初回サインイン後に 1 回だけ実質的に書き込まれる(以降は同値で idempotent)。
    func updateAppleUserId(_ appleUserId: String) async throws {
        guard let userId = try? await client.auth.session.user.id else {
            throw RoomError.notAuthenticated
        }
        try await client
            .from("profiles")
            .update(["apple_user_id": appleUserId])
            .eq("id", value: userId.uuidString)
            .execute()
    }

    // =========================================================================
    // MARK: - v0.2 API (DEPRECATED)
    // =========================================================================
    // 既存コード(HomeViewModel.loadMyRoom 等)のコンパイルを維持するためスタブを残す。
    // v0.4 schema では `rooms.code` / `rooms.host_id` / `rooms.is_active` カラムが
    // 存在しないため、これらは実行すると常に schemaIncompatible を throw する。
    // 各呼び出し元は順次 v0.4 API へ移行する。

    @available(*, deprecated, message: "v0.4 では fetchMyRoomV4() を使う。v0.2 schema は廃止された。")
    func fetchMyRoom() async throws -> Room {
        throw RoomError.schemaIncompatible
    }

    @available(*, deprecated, message: "v0.4 ではコード入力 → ペアリング申請。M3 で PairService.requestPair() に置換予定。")
    func joinRoom(code: String) async throws -> Room {
        throw RoomError.schemaIncompatible
    }

    // =========================================================================
    // MARK: - 共通(維持)
    // =========================================================================

    /// 曲情報の DB 永続化(遅延参加ゲスト用)。
    /// M5(Shared モード)で last-write-wins 用に大幅拡張予定。
    func updateCurrentSong(roomId: String, songId: String) async throws {
        try await client
            .from("rooms")
            .update(["current_song_id": songId])
            .eq("id", value: roomId)
            .execute()
    }

    /// アカウント削除。v0.2 では `delete_my_account` RPC を使っていたが、v0.4 schema には
    /// 同 RPC を含めていない。M8 仕上げ時に再設計する想定。
    /// 暫定: schemaIncompatible を throw。SettingsSheet 側で alert 表示 → "M8 で対応予定" と案内。
    func deleteAccount() async throws {
        throw RoomError.schemaIncompatible
    }

    /// shared_room から退出(M5 で本格対応、M2 段階では呼ばれない想定)
    func leaveRoom(roomId: String, isHost: Bool) async throws {
        if isHost { return }
        guard let userId = try? await client.auth.session.user.id else {
            throw RoomError.notAuthenticated
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try await client
            .from("room_participants")
            .update(["left_at": iso.string(from: Date())])
            .eq("room_id", value: roomId)
            .eq("user_id", value: userId.uuidString)
            .is("left_at", value: nil)
            .execute()
    }
}
