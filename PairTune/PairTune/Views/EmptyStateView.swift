import SwiftUI

// MARK: - EmptyStateView (v0.4 Empty / Error 状態画面)
//
// デザイン: Claude Design v2 `screens-album-extras.jsx` の `EmptyStateScreen`
//
// 3 種類 (kind):
//   - .noResults : 検索結果なし
//   - .offline   : インターネット切断
//   - .authError : Apple Music 未契約 or 認可なし
//
// 中央寄せ 72pt icon + 日英 2 行タイトル + 説明 + primary gradient CTA
// 異常系画面として再利用される(将来 SearchSheet / RoomView 等から呼び出し)。

enum EmptyStateKind {
    case noResults
    case offline
    case authError
}

struct EmptyStateView: View {
    let kind: EmptyStateKind
    /// 結果なし時は検索キーワードを差し込めるよう description を上書き可能。
    var descriptionOverride: String? = nil

    var onBack: (() -> Void)? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            VStack(spacing: 0) {
                if let onBack {
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(hex: "A8A8A8"))
                                .frame(width: 38, height: 38)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.05))
                                        .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                                )
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                } else {
                    Color.clear.frame(height: 46)
                }

                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    iconRound
                    Text(titleJa)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .tracking(0.2)
                        .padding(.top, 18)
                    Text(titleEn)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "5A5566"))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .padding(.top, 4)
                    Text(descriptionOverride ?? descriptionDefault)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "A8A8A8"))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .tracking(0.2)
                        .padding(.top, 14)
                        .padding(.horizontal, 32)

                    if let onAction {
                        Button(action: onAction) {
                            Text(actionLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 14, y: 6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                        )
                                )
                        }
                        .padding(.top, 22)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Icon

    private var iconRound: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(isDanger ? Color(hex: "E85B6B").opacity(0.10) : Color.pairtunePrimary.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            isDanger
                                ? Color(hex: "E85B6B").opacity(0.25)
                                : Color.pairtunePrimary.opacity(0.30),
                            lineWidth: 0.5
                        )
                )
                .frame(width: 72, height: 72)
            Image(systemName: iconName)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(isDanger ? Color(hex: "E85B6B") : .pairtunePrimary)
        }
    }

    // MARK: - Strings

    private var iconName: String {
        switch kind {
        case .noResults: return "magnifyingglass"
        case .offline:   return "wifi.slash"
        case .authError: return "lock"
        }
    }

    private var isDanger: Bool { kind == .offline }

    private var titleJa: String {
        switch kind {
        case .noResults: return "見つかりません"
        case .offline:   return "オフライン"
        case .authError: return "Apple Music にアクセスできません"
        }
    }

    private var titleEn: String {
        switch kind {
        case .noResults: return "No results"
        case .offline:   return "You’re offline"
        case .authError: return "Apple Music unavailable"
        }
    }

    private var descriptionDefault: String {
        switch kind {
        case .noResults: return "検索条件に一致する曲は見つかりませんでした。"
        case .offline:   return "インターネット接続を確認してください。\nオンラインに戻ったら自動で再接続します。"
        case .authError: return "再生には Apple Music サブスクリプションと、\nApple Music へのアクセス許可が必要です。"
        }
    }

    private var actionLabel: String {
        switch kind {
        case .noResults: return "検索条件を変える"
        case .offline:   return "再試行"
        case .authError: return "設定を開く"
        }
    }
}

#Preview("no-results") { EmptyStateView(kind: .noResults, onBack: {}, onAction: {}) }
#Preview("offline")    { EmptyStateView(kind: .offline,    onBack: {}, onAction: {}) }
#Preview("auth-error") { EmptyStateView(kind: .authError,  onBack: {}, onAction: {}) }
