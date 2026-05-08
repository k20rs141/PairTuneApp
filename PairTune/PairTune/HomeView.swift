import SwiftUI

// MARK: - HomeView (v0.4 Claude Design v2)
//
// 仕様: Claude Design `screens-home-v04.jsx` の state A (pre-pairing) を実装。
// state B / C / anniversary は M3 以降で追加(現状は state A のみ)。
//
// 構成:
//   ・トップバー: 小さい WaveLogo + PairTune ワードマーク (左) / 設定アイコン (右)
//   ・ヒーロー: 中央 WaveLogo + タグライン (日本語 / 英語)
//   ・CTA スタック (下部):
//       - CodeChip: 自分のペアリングコード(タップで招待シート — M3 で実装)
//       - PrimaryButton: 「コードで参加」(M2 では disabled、M3 で PairService 接続)
//       - Divider "OR"
//       - GhostButton: 「ひとりで聴く」(M2 では disabled、M4 で Solo モード起動)

struct HomeView: View {
    /// 自分の pairing_code(AuthViewModel から流す)。nil なら "------"
    var pairingCode: String?

    /// CTA ハンドラ(M2 段階では未配線)
    var onShareCode: () -> Void = {}
    var onJoin: () -> Void = {}
    var onSolo: () -> Void = {}
    var onProfile: () -> Void = {}

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
                preHero
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

    // MARK: - Pre-pairing hero (logo + tagline)

    private var preHero: some View {
        VStack(spacing: 0) {
            PairTuneLogoView(size: 170, glow: true)

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
        .padding(.horizontal, 24)
    }

    // MARK: - CTA stack

    private var ctaStack: some View {
        VStack(spacing: 10) {
            codeChip
            joinButton
            orDivider
            soloButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 38)
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
            .disabled(true)        // M2: 招待シートは M3 で実装
            .opacity(0.5)
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
        .disabled(true)        // M2: ペアリングフローは M3 で実装
        .opacity(0.55)
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
        .disabled(true)        // M2: Solo モードは M4 で実装
        .opacity(0.55)
    }
}

#Preview {
    HomeView(pairingCode: "KP3X7M")
}
