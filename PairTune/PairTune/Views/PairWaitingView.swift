import SwiftUI
import Combine

// MARK: - PairWaitingView (v0.4 ペアリング申請待ち / A 側)
//
// 仕様: docs/PairTune_Specification_v0.4.md §5.6 / §6
// デザイン: Claude Design v2 `screens-pair-flow.jsx` PairWaitingScreen
//
// コード入力 → 申請送信 (`pairViewModel.sendState == .waiting`) の間表示される画面。
// 左に自分のアバター(active, glow + 3 重リップル)、右に相手のアバター(dim + dashed border)、
// 中央にダッシュ波線で「申請中」を表現する。
// 24h カウントダウンは `outgoingRequest.expiresAt` ベースで計算。
// 相手の承認で `activePair` が立つと自動的に閉じる(ContentView 側で制御)。

struct PairWaitingView: View {
    let targetCode: String?
    let expiresAt: Date?
    let myInitial: String

    var onCancel: () -> Void
    var onClose: () -> Void

    @State private var now: Date = .now
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // Ambient glow — clipped
            Color.clear
                .overlay(alignment: .top) {
                    Circle()
                        .fill(Color.pairtunePrimary.opacity(0.15))
                        .frame(width: 480, height: 480)
                        .blur(radius: 60)
                        .offset(y: -240)
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                heroBlock
                Spacer(minLength: 0)
                footerButtons
            }
        }
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Text("キャンセル")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "A8A8A8"))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
            }

            Spacer()

            Text("申請中 · PENDING")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "7A7588"))
                .tracking(0.5)

            Spacer()

            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Hero block

    private var heroBlock: some View {
        VStack(spacing: 0) {
            avatarsRow
                .frame(height: 130)

            VStack(spacing: 8) {
                Text("相手の承認を\n待っています")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .tracking(0.2)
                Text("Waiting for partner to approve")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "7A7588"))
                    .tracking(0.3)
            }
            .padding(.top, 24)

            countdownCard
                .padding(.top, 26)
                .padding(.horizontal, 28)

            Text("このまま閉じても大丈夫です。\n承認されたら通知でお知らせします。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "5A5566"))
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.top, 18)
        }
    }

    private var avatarsRow: some View {
        ZStack {
            // ripples emitting from me (left)
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.pairtunePrimary.opacity(0.27), lineWidth: 1)
                    .frame(width: 80, height: 80)
                    .scaleEffect(rippleScale(seed: i))
                    .opacity(rippleOpacity(seed: i))
                    .offset(x: -70)
                    .animation(
                        .easeOut(duration: 2.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.6),
                        value: now
                    )
            }

            HStack(spacing: 0) {
                meAvatar
                connectingWave
                    .frame(width: 90, height: 24)
                    .opacity(0.7)
                partnerAvatarDim
            }
        }
    }

    private var meAvatar: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.pairtunePrimary, Color.pairtunePrimary.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 64, height: 64)
            .overlay(
                Text(myInitial)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color(red: 0x0A/255, green: 0x06/255, blue: 0x12/255))
            )
            .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1.5))
            .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 14, y: 6)
    }

    private var partnerAvatarDim: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.pairtuneSecondary, Color.pairtuneSecondary.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 64, height: 64)
            .overlay(
                Text("?")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color(red: 0x0A/255, green: 0x06/255, blue: 0x12/255))
            )
            .overlay(
                Circle().stroke(
                    Color.white.opacity(0.20),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
            )
            .opacity(0.45)
            .saturation(0.6)
    }

    /// dashed wave between the two avatars (animated)
    private var connectingWave: some View {
        Canvas { ctx, size in
            let h = size.height
            let w = size.width
            let mid = h / 2
            var path = Path()
            path.move(to: CGPoint(x: 1, y: mid))
            let cycle: CGFloat = w / 8
            var x: CGFloat = 1
            var up = true
            while x < w - 1 {
                let next = min(x + cycle, w - 1)
                let ctrlY = up ? mid - 8 : mid + 8
                path.addQuadCurve(
                    to: CGPoint(x: next, y: mid),
                    control: CGPoint(x: (x + next) / 2, y: ctrlY)
                )
                x = next
                up.toggle()
            }
            ctx.stroke(
                path,
                with: .color(Color.pairtunePrimary),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 3])
            )
        }
    }

    // MARK: - Countdown card

    private var countdownCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(countdownString)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .tracking(1)
                Text("有効期限まで · expires in")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "5A5566"))
                    .tracking(0.5)
            }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                if let targetCode {
                    Text(targetCode)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.pairtunePrimary)
                        .tracking(3)
                }
                Text("申請から 24h 以内に承認されないと、自動的に失効します。")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "7A7588"))
                    .lineSpacing(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        )
    }

    private var countdownString: String {
        guard let expiresAt else { return "--:--:--" }
        let remaining = max(0, expiresAt.timeIntervalSince(now))
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Footer

    private var footerButtons: some View {
        VStack(spacing: 10) {
            Button(action: onCancel) {
                Text("申請を取り消す")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "E85B6B"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(hex: "E85B6B").opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color(hex: "E85B6B").opacity(0.20), lineWidth: 0.5)
                            )
                    )
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 36)
    }

    // MARK: - Ripple helpers

    private func rippleScale(seed: Int) -> CGFloat {
        // Use seconds since reference as a 0→2.6 ramp per ripple
        let phase = (now.timeIntervalSinceReferenceDate + Double(seed) * 0.6)
            .truncatingRemainder(dividingBy: 2.4) / 2.4
        return 0.6 + CGFloat(phase) * 2.0
    }

    private func rippleOpacity(seed: Int) -> Double {
        let phase = (now.timeIntervalSinceReferenceDate + Double(seed) * 0.6)
            .truncatingRemainder(dividingBy: 2.4) / 2.4
        return 0.9 * (1 - phase)
    }
}
