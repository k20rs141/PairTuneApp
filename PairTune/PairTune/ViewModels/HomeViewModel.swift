import Foundation

@Observable
@MainActor
final class HomeViewModel {
    /// v0.4: マイルーム(必要になった時のみロード)
    /// 状態 A(ペアリング前)では未使用。M4(Solo モード起動時)で本格的に使う。
    var myRoom: RoomV4?

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
}
