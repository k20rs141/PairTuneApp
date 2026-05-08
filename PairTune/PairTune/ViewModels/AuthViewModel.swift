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

    private var currentNonce: String?
    private let supabase = SupabaseManager.shared.client

    override init() {
        super.init()
        Task { await observeAuthState() }
    }

    // MARK: - Session restore

    func restoreSession() async {
        do {
            session = try await supabase.auth.session
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
            default:
                break
            }
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

            do {
                try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                )
                // 成功時: session 変化を authStateChanges で観測 → ContentView が画面遷移
            } catch {
                print("[AuthViewModel] Supabase signIn error:", error)
                lastError = "サインインに失敗しました。もう一度お試しください"
            }
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
