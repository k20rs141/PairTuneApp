import SwiftUI
import Combine

// MARK: - PairApprovalSheet (v0.4 ペアリング承認モーダル)
//
// 仕様: docs/PairTune_Specification_v0.4.md §5.6 / §6
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §6.4
//
// ⚠️ デザイン暫定版 (v0.4-M3 placeholder)
// Claude Design v2 `screens-pairing-approval.jsx` の bundle が共有された段階で
// レイアウト/トランジション/承認時のセレブレーション演出を差し替える。
// 現状はデータフロー検証用の最小実装。

struct PairApprovalSheet: View {
    let request: PairRequest
    let requester: ProfileV4?

    var onAccept: () -> Void
    var onReject: () -> Void
    var onDefer: () -> Void

    @State private var now: Date = .now
    @State private var isProcessing: Bool = false

    /// 1秒ごとに current time を更新してカウントダウンを動かす
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.pairtuneSurfaceSheet.ignoresSafeArea()

            VStack(spacing: 0) {
                // Handle bar
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 22)

                Text("ペアリング申請が届いています")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(0.2)

                Text("Pairing request received")
                    .font(.system(size: 12))
                    .foregroundColor(.pairtuneTextTertiary)
                    .tracking(0.4)
                    .padding(.top, 4)

                Spacer(minLength: 18)

                // Avatar + name
                VStack(spacing: 12) {
                    avatar
                    Text(requester?.displayName ?? "User")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)

                    if let code = requester?.pairingCode {
                        Text(code)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.pairtuneTextTertiary)
                            .tracking(2)
                    }
                }

                Spacer(minLength: 16)

                // Countdown
                countdownBlock

                Spacer(minLength: 24)

                // Actions
                VStack(spacing: 10) {
                    acceptButton
                    rejectButton
                    deferButton
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onReceive(timer) { now = $0 }
        .interactiveDismissDisabled(isProcessing)
    }

    // MARK: - Pieces

    private var avatar: some View {
        let initial = (requester?.displayName.first.map(String.init) ?? "?").uppercased()
        return Circle()
            .fill(
                LinearGradient(
                    colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 78, height: 78)
            .overlay(
                Text(initial)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
            )
            .overlay(
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: Color.pairtunePrimary.opacity(0.35), radius: 18, y: 6)
    }

    private var countdownBlock: some View {
        let remaining = max(0, request.expiresAt.timeIntervalSince(now))
        return VStack(spacing: 4) {
            Text("有効期限まで")
                .font(.system(size: 11))
                .foregroundColor(.pairtuneTextTertiary)
                .tracking(0.5)
                .textCase(.uppercase)
            Text(formatRemaining(remaining))
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(remaining < 3600 ? .pairtuneSyncBad : .pairtuneTextSecondary)
        }
    }

    private var acceptButton: some View {
        Button(action: handleAccept) {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill").font(.system(size: 16))
                Text("承認する")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 14, y: 5)
            )
        }
        .disabled(isProcessing)
        .opacity(isProcessing ? 0.6 : 1.0)
    }

    private var rejectButton: some View {
        Button(action: handleReject) {
            Text("拒否する")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.pairtuneTextSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                )
        }
        .disabled(isProcessing)
    }

    private var deferButton: some View {
        Button(action: onDefer) {
            Text("あとで決める")
                .font(.system(size: 13))
                .foregroundColor(.pairtuneTextTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
        }
        .disabled(isProcessing)
    }

    // MARK: - Handlers

    private func handleAccept() {
        isProcessing = true
        onAccept()
    }

    private func handleReject() {
        isProcessing = true
        onReject()
    }

    // MARK: - Helpers

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d時間 %02d分", h, m)
        } else {
            return String(format: "%02d:%02d", m, sec)
        }
    }
}
