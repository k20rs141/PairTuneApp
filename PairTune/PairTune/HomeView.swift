import SwiftUI

// MARK: - HomeView (v0.4 Claude Design v2)
//
// 仕様: docs/PairTune_Specification_v0.4.md §5.2
// 状態:
//   A. ペアリング前 (partnerName == nil)
//      タグライン + コードチップ + 「コードで参加」+ OR + 「ひとりで聴く」
//   B. ペアリング済み (partnerName != nil)
//      パートナー名 + 「○○ さんと聴く」(M5 まで disabled) + OR + 「ひとりで聴く」
//   C. オフライン分岐 (M3 範囲外、partnerOnline は M5 で配線)
//
// CLAUDE.md の View レイアウト変更禁止に配慮し、骨格・パディング・スタイルは維持。
// state B では文言とアイコンだけ差し替え。

struct HomeView: View {
    /// 自分の pairing_code(state A 表示用)。nil なら "------"
    var pairingCode: String?

    /// パートナーの表示名(state B 表示用)。nil なら state A。
    var partnerName: String? = nil

    /// CTA ハンドラ
    var onShareCode: () -> Void = {}
    var onJoin: () -> Void = {}
    var onListenWithPartner: () -> Void = {}
    var onSolo: () -> Void = {}
    var onProfile: () -> Void = {}

    private var isPaired: Bool { partnerName != nil }

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // ── ambient glows ──
            GeometryReader { _ in
                ZStack {
                    Circle()
                        .fill(Color.pairtunePrimary.opacity(0.18))
                        .frame(width: 420, height: 420)
                        .blur(radius: 55)
                        .offset(x: 140, y: -120)
                    Circle()
                        .fill(Color.pairtuneSecondary.opacity(0.12))
                        .frame(width: 340, height: 340)
                        .blur(radius: 50)
                        .offset(x: -160, y: 240)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                hero
                Spacer(minLength: 0)
                ctaStack
            }
        }
    }

    // MARK: - Top bar (logo lockup + gear)

    private var topBar: some View {
        HStack {
            HStack(spacing: 10) {
                PairTuneLogoView(size: 48)
                    .frame(height: 17)
                PairTuneWordmark(size: 16, color: .white.opacity(0.82))
            }
            Spacer()
            Button(action: onProfile) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.pairtuneTextSecondary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.05))
                            .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                    )
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    // MARK: - Hero (state A: tagline / state B: partner name)

    private var hero: some View {
        VStack(spacing: 0) {
            PairTuneLogoView(size: 170, glow: true)

            if isPaired, let partnerName {
                Text("\(partnerName) さんと\nつながっています")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .tracking(0.2)
                    .padding(.top, 24)

                Text("Paired up — ready to listen together.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.pairtuneTextTertiary)
                    .tracking(0.6)
                    .padding(.top, 8)
            } else {
                Text("離れていても、\n同じ音を。")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .tracking(0.2)
                    .padding(.top, 24)

                Text("Tune in, side by side — without a call.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.pairtuneTextTertiary)
                    .tracking(0.6)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - CTA stack

    private var ctaStack: some View {
        VStack(spacing: 10) {
            partnerOrCodeChip
            primaryButton
            orDivider
            soloButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 38)
    }

    @ViewBuilder
    private var partnerOrCodeChip: some View {
        if isPaired, let partnerName {
            partnerChip(name: partnerName)
        } else {
            codeChip
        }
    }

    private var codeChip: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("あなたのコード")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "7A7588"))
                    .tracking(0.6)
                    .textCase(.uppercase)
                Text(pairingCode ?? "------")
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundColor(.pairtunePrimary)
                    .tracking(5)
            }
            Spacer(minLength: 0)
            Button(action: onShareCode) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundColor(.pairtuneTextSecondary)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                            )
                    )
            }
            .disabled(pairingCode == nil)
            .opacity(pairingCode == nil ? 0.5 : 1.0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.pairtunePrimary.opacity(0.10),
                            Color.pairtuneSecondary.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    private func partnerChip(name: String) -> some View {
        HStack(spacing: 12) {
            // ペアステータスドット (M5 で online/offline 反映予定。現状は「ペア成立」表示)
            Circle()
                .fill(Color.pairtuneSyncOk)
                .frame(width: 8, height: 8)
                .shadow(color: Color.pairtuneSyncOk.opacity(0.5), radius: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text("パートナー")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "7A7588"))
                    .tracking(0.6)
                    .textCase(.uppercase)
                Text(name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.pairtunePrimary.opacity(0.10),
                            Color.pairtuneSecondary.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var primaryButton: some View {
        if isPaired, let partnerName {
            listenWithPartnerButton(partnerName: partnerName)
        } else {
            joinButton
        }
    }

    private var joinButton: some View {
        Button(action: onJoin) {
            HStack(spacing: 10) {
                Image(systemName: "door.left.hand.open")
                    .font(.system(size: 16))
                Text("コードで参加")
                    .font(.system(size: 15, weight: .semibold))
                Text("· Join with code")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 16, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
        }
    }

    /// state B 用の主 CTA。M5(Shared モード)まで実機能 disabled、見た目だけ paired 表現。
    private func listenWithPartnerButton(partnerName: String) -> some View {
        Button(action: onListenWithPartner) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                Text("\(partnerName) さんと聴く")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 16, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
        }
    }

    private var orDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            Text("OR")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "3F3F4A"))
                .tracking(0.6)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var soloButton: some View {
        Button(action: onSolo) {
            HStack(spacing: 9) {
                Image(systemName: "music.note")
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "7A7588"))
                Text("ひとりで聴く")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.pairtuneTextSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
    }
}

#Preview("State A (pre-pairing)") {
    HomeView(pairingCode: "KP3X7M")
}

#Preview("State B (paired)") {
    HomeView(pairingCode: "KP3X7M", partnerName: "さくら")
}
