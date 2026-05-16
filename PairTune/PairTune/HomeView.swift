import SwiftUI
import UIKit

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

    /// 自分の表示名(paired hero のアバター initial 用)
    var myName: String? = nil

    /// パートナーの表示名(state B 表示用)。nil なら state A。
    var partnerName: String? = nil
    /// 自分の avatar 画像 URL(profiles.avatar_url)。nil の時はイニシャル fallback。
    var myAvatarUrl: String? = nil
    /// 相手の avatar 画像 URL。
    var partnerAvatarUrl: String? = nil

    /// パートナーのオンライン状況。true: online(緑ドット + 接続波 active)/
    /// false: offline(グレードット + 接続波 dim + アバター dim)
    var partnerOnline: Bool = true

    /// オフライン時に表示する「最終オンライン日時」表示用テキスト(任意)
    var partnerLastSeen: String? = nil

    /// CTA ハンドラ
    var onShareCode: () -> Void = {}
    var onJoin: () -> Void = {}
    var onListenWithPartner: () -> Void = {}
    var onSolo: () -> Void = {}
    var onProfile: () -> Void = {}
    /// オフライン時の「部屋を開いて待つ」CTA(任意。nil なら表示しない)
    var onOpenAndWait: (() -> Void)? = nil

    private var isPaired: Bool { partnerName != nil }

    @State private var toastMessage: String?

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

            // Toast overlay (コードコピー時の確認用)
            if let msg = toastMessage {
                VStack {
                    Spacer()
                    ToastView(message: msg)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .padding(.bottom, 130)
                }
                .animation(.easeOut(duration: 0.25), value: toastMessage != nil)
                .allowsHitTesting(false)
            }
        }
    }

    /// pairingCode をクリップボードへコピーし、haptic + トーストで確認表示する。
    private func copyPairingCode() {
        guard let code = pairingCode, !code.isEmpty else { return }
        UIPasteboard.general.string = code
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { toastMessage = "コードをコピーしました" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { toastMessage = nil }
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
                // ユーザーのアバター(設定で変更可能)を表示。URL 無しならイニシャルでフォールバック。
                RemoteAvatarView(
                    url: myAvatarUrl.flatMap(URL.init(string:)),
                    initials: initialOf(myName ?? "YO"),
                    color: .pairtunePrimary,
                    size: 36,
                    strokeColor: Color.white.opacity(0.08),
                    strokeWidth: 0.5
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    // MARK: - Hero (state A: tagline / state B: partner avatar + wave)

    @ViewBuilder
    private var hero: some View {
        if isPaired, let partnerName {
            pairedHero(partnerName: partnerName)
                .padding(.horizontal, 24)
        } else {
            preHero
                .padding(.horizontal, 24)
        }
    }

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
    }

    /// 2 アバター hero(自分 + パートナー)+ 接続波 + ステータス。
    private func pairedHero(partnerName: String) -> some View {
        VStack(spacing: 0) {
            // 2 アバター + 接続波
            ZStack {
                Color.clear.frame(height: 88)

                HStack(spacing: 22) {
                    RemoteAvatarView(
                        url: myAvatarUrl.flatMap(URL.init(string:)),
                        initials: initialOf(myName ?? "YO"),
                        color: .pairtunePrimary,
                        size: 62,
                        strokeColor: Color.white.opacity(0.08),
                        strokeWidth: 1.5,
                        dim: false
                    )
                    RemoteAvatarView(
                        url: partnerAvatarUrl.flatMap(URL.init(string:)),
                        initials: initialOf(partnerName),
                        color: Color(hex: "FF6B9D"),
                        size: 62,
                        strokeColor: Color.white.opacity(0.08),
                        strokeWidth: 1.5,
                        dim: !partnerOnline
                    )
                }

                // connector wave between the two
                ConnectorWaveView(primary: .pairtunePrimary, secondary: .pairtuneSecondary, active: partnerOnline)
                    .frame(width: 62, height: 28)
            }

            // status row
            HStack(spacing: 10) {
                Text("\(partnerName) さん")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .tracking(0.1)
            }
            .padding(.top, 16)

            HStack(spacing: 7) {
                Circle()
                    .fill(partnerOnline ? Color.pairtuneSyncOk : Color(hex: "5A5566"))
                    .frame(width: 6, height: 6)
                    .shadow(color: partnerOnline ? Color.pairtuneSyncOk.opacity(0.8) : .clear, radius: 4)
                Text(partnerOnline
                     ? "オンライン · online"
                     : (partnerLastSeen.map { "最後にオンライン: \($0)" } ?? "オフライン · offline"))
                    .font(.system(size: 11.5))
                    .foregroundColor(partnerOnline ? Color.pairtuneSyncOk : Color(hex: "5A5566"))
                    .tracking(0.4)
            }
            .padding(.top, 5)
        }
    }

    private func homeAvatar(initial: String, color: Color, dim: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 62, height: 62)
                .overlay(
                    Text(initial)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Color(red: 0x0A/255, green: 0x06/255, blue: 0x12/255))
                )
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1.5))
                .opacity(dim ? 0.55 : 1.0)
                .saturation(dim ? 0.5 : 1.0)
        }
    }

    private func initialOf(_ name: String) -> String {
        String(name.prefix(2)).uppercased()
    }

    // MARK: - CTA stack

    @ViewBuilder
    private var ctaStack: some View {
        if isPaired {
            pairedCtaStack
        } else {
            unpairedCtaStack
        }
    }

    private var unpairedCtaStack: some View {
        VStack(spacing: 10) {
            codeChip
            joinButton
            orDivider
            soloButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 38)
    }

    @ViewBuilder
    private var pairedCtaStack: some View {
        if partnerOnline {
            // Online: 「○○ さんと聴く」(big primary) + 「ひとりで聴く」
            VStack(spacing: 10) {
                listenWithPartnerButton(partnerName: partnerName ?? "")
                soloButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 38)
        } else {
            // Offline: 「ひとりで聴く」(big primary, promoted) + 「部屋を開いて待つ」
            VStack(spacing: 10) {
                soloPromotedButton
                if let onOpenAndWait {
                    openAndWaitButton(action: onOpenAndWait)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 38)
        }
    }

    private var soloPromotedButton: some View {
        Button(action: onSolo) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                Text("ひとりで聴く")
                    .font(.system(size: 15, weight: .semibold))
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

    private func openAndWaitButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "door.left.hand.open")
                        .font(.system(size: 15))
                    Text("部屋を開いて待つ")
                        .font(.system(size: 14, weight: .medium))
                }
                Text("\(partnerName ?? "相手") さんが来たら通知します")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.4)
            }
            .foregroundColor(Color(hex: "A8A8A8"))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.pairtunePrimary.opacity(0.27), lineWidth: 0.5)
                    )
            )
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
            Button(action: copyPairingCode) {
                Image(systemName: "doc.on.doc")
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

// MARK: - Connector wave between two avatars

private struct ConnectorWaveView: View {
    let primary: Color
    let secondary: Color
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let w = size.width
            let mid = h / 2
            let opacity = active ? 0.85 : 0.25

            var upper = Path()
            upper.move(to: CGPoint(x: 1, y: mid))
            let cycle = w / 4
            var x: CGFloat = 1
            while x < w - 1 {
                let next = min(x + cycle, w - 1)
                upper.addQuadCurve(
                    to: CGPoint(x: next, y: mid),
                    control: CGPoint(x: (x + next) / 2, y: mid - 6)
                )
                x = next
            }

            var lower = Path()
            lower.move(to: CGPoint(x: 1, y: mid))
            x = 1
            while x < w - 1 {
                let next = min(x + cycle, w - 1)
                lower.addQuadCurve(
                    to: CGPoint(x: next, y: mid),
                    control: CGPoint(x: (x + next) / 2, y: mid + 6)
                )
                x = next
            }

            ctx.stroke(
                upper,
                with: .color(primary.opacity(opacity)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
            ctx.stroke(
                lower,
                with: .color(secondary.opacity(opacity)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
        }
    }
}

#Preview("State A (pre-pairing)") {
    HomeView(pairingCode: "KP3X7M")
}

#Preview("State B online") {
    HomeView(pairingCode: "KP3X7M", myName: "あなた", partnerName: "さくら", partnerOnline: true)
}

#Preview("State B offline") {
    HomeView(
        pairingCode: "KP3X7M",
        myName: "あなた",
        partnerName: "さくら",
        partnerOnline: false,
        partnerLastSeen: "2 時間前",
        onOpenAndWait: {}
    )
}
