import Foundation
import AuthenticationServices
import CryptoKit
import Supabase

@Observable
@MainActor
final class AuthViewModel: NSObject {
    var session: Session?
    var isLoading = false
    var lastError: String?

    /// v0.4 で追加: 自分のプロフィール(サインイン後にロード)
    var currentProfile: ProfileV4?

    /// v0.4 で追加: ペアリングコード(派生プロパティ、ホーム状態 A 表示用)
    var pairingCode: String? { currentProfile?.pairingCode }

    private var currentNonce: String?
    /// Apple Sign In credential.user(初回サインインで profiles に永続化するまで保持)
    private var pendingAppleUserId: String?
    private let supabase = SupabaseManager.shared.client
    private let roomService = RoomService()

    override init() {
        super.init()
        Task { await observeAuthState() }
    }

    // MARK: - Session restore

    func restoreSession() async {
        do {
            session = try await supabase.auth.session
            // 既存セッションがあればプロフィールも復元
            if session != nil {
                await loadProfile()
            }
        } catch {
            session = nil
        }
    }

    // MARK: - Auth state observation

    private func observeAuthState() async {
        for await (event, newSession) in supabase.auth.authStateChanges {
            switch event {
            case .signedIn, .tokenRefreshed, .userUpdated:
                session = newSession
            case .signedOut:
                session = nil
                currentProfile = nil
            default:
                break
            }
        }
    }

    // MARK: - Profile loading

    /// プロフィール再読み込み(state A の pairing_code 表示用)。失敗してもクラッシュしない。
    func loadProfile() async {
        do {
            currentProfile = try await roomService.fetchMyProfile()
        } catch {
            print("[AuthViewModel] loadProfile error:", error)
            // lastError には出さない(画面で「------」表示されるだけ)
        }
    }

    // MARK: - Sign in with Apple

    func signInWithApple() async {
        let nonce = randomNonce()
        currentNonce = nonce
        isLoading = true
        lastError = nil
        // NOTE: isLoading は performRequests() 後の async コールバックで完了するため、
        //       ここで defer リセットせず delegate メソッド側で false にする。

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - Privacy settings (M6)

    /// share_play_history / share_favorites を更新し、ローカルの currentProfile にも反映する。
    func updatePrivacySettings(sharePlayHistory: Bool, shareFavorites: Bool) async {
        do {
            try await roomService.updatePrivacySettings(
                sharePlayHistory: sharePlayHistory,
                shareFavorites: shareFavorites
            )
            currentProfile?.sharePlayHistory = sharePlayHistory
            currentProfile?.shareFavorites = shareFavorites
        } catch {
            print("[AuthViewModel] updatePrivacySettings error:", error)
            lastError = "設定の保存に失敗しました"
        }
    }

    /// 通知設定を更新し、ローカルの currentProfile にも反映する。
    func updateNotificationSettings(notifyPartnerOnline: Bool, notifyMilestones: Bool) async {
        do {
            try await roomService.updateNotificationSettings(
                notifyPartnerOnline: notifyPartnerOnline,
                notifyMilestones: notifyMilestones
            )
            currentProfile?.notifyPartnerOnline = notifyPartnerOnline
            currentProfile?.notifyMilestones = notifyMilestones
        } catch {
            print("[AuthViewModel] updateNotificationSettings error:", error)
            lastError = "通知設定の保存に失敗しました"
        }
    }

    /// プロフィール画像を Supabase Storage にアップロードし、profiles.avatar_url を更新。
    /// 成功時は currentProfile にも反映する。
    func updateAvatarImage(jpegData: Data) async -> Bool {
        do {
            let newUrl = try await roomService.uploadAvatar(jpegData: jpegData)
            currentProfile?.avatarUrl = newUrl
            return true
        } catch {
            print("[AuthViewModel] updateAvatarImage error:", error)
            lastError = "プロフィール画像の更新に失敗しました"
            return false
        }
    }

    /// 表示名を更新。空文字列は無視。
    func updateDisplayName(_ newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentProfile?.displayName else { return }
        do {
            try await roomService.updateDisplayName(trimmed)
            currentProfile?.displayName = trimmed
        } catch {
            print("[AuthViewModel] updateDisplayName error:", error)
            lastError = "表示名の更新に失敗しました"
        }
    }

    // MARK: - Sign out

    func signOut() async {
        do {
            try await supabase.auth.signOut()
        } catch {
            print("[AuthViewModel] signOut error:", error)
            lastError = "ログアウトに失敗しました"
        }
    }

    // MARK: - Delete account

    /// アカウント削除 → 自動でサインアウト状態へ。失敗時は lastError を立てて false 返却。
    func deleteAccount() async -> Bool {
        do {
            try await RoomService().deleteAccount()
            try? await supabase.auth.signOut()
            session = nil
            return true
        } catch {
            print("[AuthViewModel] deleteAccount error:", error)
            lastError = "アカウント削除に失敗しました。しばらくしてから再度お試しください"
            return false
        }
    }

    // MARK: - Nonce helpers

    private func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        assert(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(length)
            .description
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hash = SHA256.hash(data: inputData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthViewModel: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            defer { isLoading = false }
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                print("[AuthViewModel] Apple credential invalid")
                lastError = "認証に失敗しました"
                return
            }

            // Apple の安定識別子(同一ユーザーで毎回同じ)を保持。
            // Supabase 認証成功後に profiles.apple_user_id へ書き込む。
            pendingAppleUserId = credential.user

            do {
                try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                )
                // 成功時: session 変化を authStateChanges で観測 → ContentView が画面遷移
                // ここで apple_user_id 保存 + プロフィール取得を続けて行う。
                await persistAppleUserIdIfNeeded()
                await loadProfile()
            } catch {
                print("[AuthViewModel] Supabase signIn error:", error)
                lastError = "サインインに失敗しました。もう一度お試しください"
            }
        }
    }

    /// `pendingAppleUserId` を `profiles.apple_user_id` に保存。失敗してもサインインフローは続行。
    private func persistAppleUserIdIfNeeded() async {
        guard let appleUserId = pendingAppleUserId else { return }
        do {
            try await roomService.updateAppleUserId(appleUserId)
            pendingAppleUserId = nil
        } catch {
            print("[AuthViewModel] persistAppleUserId error:", error)
            // RLS エラー等の可能性があるが致命的ではないので、エラー UI は出さない。
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let nsErr = error as NSError
        let isCancel = (nsErr.domain == ASAuthorizationError.errorDomain
            && nsErr.code == ASAuthorizationError.canceled.rawValue)
        Task { @MainActor in
            isLoading = false
            if !isCancel {
                print("[AuthViewModel] Apple auth error:", error)
                lastError = "認証に失敗しました"
            }
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AuthViewModel: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
