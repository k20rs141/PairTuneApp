import Foundation

@Observable
@MainActor
final class HomeViewModel {
    /// v0.4: マイルーム(Solo モード起動時にロード)
    var myRoom: RoomV4?

    /// v0.4: Shared ルーム(Shared モード参加時にロード)
    var sharedRoom: RoomV4?

    var isLoading = false
    var lastError: String?

    private let roomService = RoomService()

    // MARK: - マイルームを取得

    /// M4 で Solo モードに入るときに呼ぶ想定。M2 段階では ContentView から呼ばない。
    func loadMyRoom() async {
        guard myRoom == nil else { return } // キャッシュ済みならスキップ
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            myRoom = try await roomService.fetchMyRoomV4()
        } catch let roomErr as RoomError {
            switch roomErr {
            case .notAuthenticated:
                lastError = "セッションが切れました。サインインし直してください"
            default:
                lastError = "接続できません。リトライしますか?"
            }
            print("[HomeViewModel] loadMyRoom error:", roomErr)
        } catch {
            lastError = "接続できません。リトライしますか?"
            print("[HomeViewModel] loadMyRoom error:", error)
        }
    }

    // MARK: - マイルームを強制リロード

    func reloadMyRoom() async {
        myRoom = nil
        await loadMyRoom()
    }

    // MARK: - Shared ルームを取得 (M5)

    /// M5 で Shared モードに入るときに呼ぶ。pairViewModel.activePair.sharedRoomId を渡す。
    func loadSharedRoom(roomId: String) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            sharedRoom = try await roomService.fetchSharedRoom(roomId: roomId)
        } catch let roomErr as RoomError {
            switch roomErr {
            case .notAuthenticated:
                lastError = "セッションが切れました。サインインし直してください"
            default:
                lastError = "接続できません。リトライしますか?"
            }
            print("[HomeViewModel] loadSharedRoom error:", roomErr)
        } catch {
            lastError = "接続できません。リトライしますか?"
            print("[HomeViewModel] loadSharedRoom error:", error)
        }
    }
}
