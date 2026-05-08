import Foundation

// ⚠️ DEPRECATED: v0.2 マイルーム単独方式の JoinRoomViewModel。
// M3 で v0.4 仕様の PairViewModel に置換予定。
// 詳細: docs/PairTune_Implementation_Guide_v0.4.md §2 / §6
// 主な変更点:
//   - コード入力 → 即 joinRoom(code:) で他人のマイルームに参加 (v0.2)
//     ↓
//   - コード入力 → PairService.requestPair(targetCode:) で pair_requests INSERT
//     → 相手側の承認 → accept_pair_request RPC で shared_room 自動生成 → 参加 (v0.4)
//   - 「申請中…」「承認待ち」「拒否された」「24h 失効」の状態管理が新たに必要

@Observable
@MainActor
final class JoinRoomViewModel {
    var isValidating = false
    var joinedRoom: Room?

    private let roomService = RoomService()

    /// コードを検証してルームに参加する。
    /// - Returns: エラーメッセージ文字列、成功時は nil
    func joinRoom(code: String) async -> String? {
        isValidating = true
        defer { isValidating = false }
        do {
            joinedRoom = try await roomService.joinRoom(code: code)
            return nil
        } catch let roomErr as RoomError {
            return roomErr.errorDescription
        } catch {
            return "接続エラー。リトライしてください"
        }
    }
}
