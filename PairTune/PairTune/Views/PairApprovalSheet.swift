import SwiftUI
import Combine

// MARK: - PairApprovalSheet (v0.4 ペアリング承認モーダル)
//
// 仕様: docs/PairTune_Specification_v0.4.md §5.6 / §6
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §6.4
// デザイン: Claude Design v2 `screens-pairing-approval.jsx`
//
// 2 モード:
//   - .incoming: 申請受信ビュー(アバター + 期限カウントダウン + 承認/拒否/あとで)
//   - .celebrating: 承認直後の演出(twin avatars + 「ペアになりました」+ 「ふたりの部屋を開く」)

struct PairApprovalSheet: View {
    enum Mode: Equatable {
        case incoming
        case celebrating(partnerName: String, partnerInitial: String)
    }

    let request: PairRequest
    let requester: ProfileV4?
    let mode: Mode
    let myInitial: String

    var onAccept: () -> Void
    var onReject: () -> Void
    var onDefer: () -> Void
    var onEnterRoom: () -> Void

    @State private var now: Date = .now
    @State private var isProcessing: Bool = false
    @State private var pulseTrigger: Int = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let glowIntensity: Double = mode == .incoming ? 0.17 : 0.28
        return ZStack {
            Color(red: 0x0C/255, green: 0x08/255, blue: 0x18/255).ignoresSafeArea()

            // Background glows — clipped to sheet bounds so the 520/360pt circles don't expand the parent
            Color.clear
                .overlay {
                    ZStack {
                        Circle()
                            .fill(Color.pairtunePrimary.opacity(glowIntensity))
                            .frame(width: 520, height: 520)
                            .blur(radius: 60)
                            .offset(y: -260)
                        Circle()
                            .fill(Color.pairtuneSecondary.opacity(mode == .incoming ? 0.12 : 0.22))
                            .frame(width: 360, height: 360)
                            .blur(radius: 50)
                            .offset(x: 130, y: 260)
                    }
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                if mode == .incoming {
                    incomingBody
                } else if case .celebrating(let partnerName, let partnerInitial) = mode {
                    celebrationBody(partnerName: partnerName, partnerInitial: partnerInitial)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isProcessing || isCelebrating)
        .onReceive(timer) { now = $0 }
        .onChange(of: mode) { _, newMode in
            if case .celebrating = newMode {
                isProcessing = false
                pulseTrigger += 1
            }
        }
    }

    private var isCelebrating: Bool {
        if case .celebrating = mode { return true }
        return false
    }

    // MARK: - Incoming body

    @ViewBuilder
    private var incomingBody: some View {
        // Top label
        HStack(spacing: 8) {
            PairTuneLogoView(size: 42)
                .frame(width: 42, height: 15)
            Text("ペアリング申請")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "7A7588"))
                .tracking(0.5)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 32)

        Spacer(minLength: 0)

        VStack(spacing: 0) {
            avatarWithWaves
            Text(displayName)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white)
                .tracking(0.2)
                .padding(.top, 24)

            if let code = requester?.pairingCode {
                Text(code)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "7A7588"))
                    .tracking(2)
                    .padding(.top, 4)
            }

            VStack(spacing: 0) {
                Text("\(displayName) さんがあなたと")
                Text("ペアリング").fontWeight(.medium).foregroundColor(.white) + Text("したがっています")
            }
            .font(.system(size: 15))
            .foregroundColor(.white.opacity(0.78))
            .multilineTextAlignment(.center)
            .lineSpacing(6)
            .padding(.top, 18)
            .padding(.horizontal, 28)

            metaCard
                .padding(.top, 22)
                .padding(.horizontal, 22)

            Text("承認すると、ふたりだけのルームが作られます。\nいつでも解消できます。")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "5A5566"))
                .tracking(0.4)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 18)
        }

        Spacer(minLength: 16)

        VStack(spacing: 10) {
            acceptButton
            HStack(spacing: 10) {
                rejectButton
                deferButton
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 36)
    }

    private var avatarWithWaves: some View {
        ZStack {
            Circle()
                .stroke(Color.pairtunePrimary.opacity(0.16), lineWidth: 0.5)
                .frame(width: 140, height: 140)
            Circle()
                .stroke(Color.pairtunePrimary.opacity(0.10), lineWidth: 0.5)
                .frame(width: 184, height: 184)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.pairtunePrimary, Color.pairtunePrimary.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 96, height: 96)
                .overlay(
                    Text(requesterInitial)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(Color(red: 0x0A/255, green: 0x06/255, blue: 0x12/255))
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 1.5)
                )
                .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 18, y: 8)
        }
    }

    private var metaCard: some View {
        let remaining = max(0, request.expiresAt.timeIntervalSince(now))
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60
        let percent = remaining / (24 * 3600)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                metaRow(key: "申請日時", value: formatDate(request.createdAt))
                metaRow(
                    key: "期限",
                    value: String(format: "%02d:%02d:%02d 残り", h, m, s),
                    valueColor: h < 6 ? Color(hex: "F4C26A") : .white
                )
            }
            Spacer(minLength: 0)
            CountdownRingView(percent: percent, accent: .pairtunePrimary)
                .frame(width: 48, height: 48)
        }
        .padding(.horizontal, 14)
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

    private func metaRow(key: String, value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "7A7588"))
                .tracking(0.3)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(valueColor)
                .tracking(0.2)
        }
    }

    private var acceptButton: some View {
        Button(action: handleAccept) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                Text("承認してペアになる")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.pairtunePrimary.opacity(0.33), radius: 16, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
        }
        .disabled(isProcessing)
        .opacity(isProcessing ? 0.6 : 1.0)
    }

    private var rejectButton: some View {
        Button(action: handleReject) {
            Text("拒否")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "E85B6B"))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: "E85B6B").opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color(hex: "E85B6B").opacity(0.25), lineWidth: 0.5)
                        )
                )
        }
        .disabled(isProcessing)
    }

    private var deferButton: some View {
        Button(action: onDefer) {
            Text("あとで")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "A8A8A8"))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
        }
        .disabled(isProcessing)
    }

    // MARK: - Celebration body

    @ViewBuilder
    private func celebrationBody(partnerName: String, partnerInitial: String) -> some View {
        Spacer(minLength: 40)

        ZStack {
            // Ripples
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.pairtunePrimary.opacity(0.25), lineWidth: 1)
                    .frame(width: 120, height: 120)
                    .scaleEffect(rippleScale(for: i))
                    .opacity(rippleOpacity(for: i))
                    .animation(
                        .easeOut(duration: 2.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.6),
                        value: pulseTrigger
                    )
            }

            // Twin avatars + wave
            HStack(spacing: 16) {
                celebrationAvatar(initial: myInitial, color: .pairtunePrimary)
                    .offset(x: 0)

                celebrationAvatar(initial: partnerInitial, color: Color(hex: "FF6B9D"))
                    .offset(x: 0)
            }

            // Connecting wave
            CelebrationWaveView(primary: .pairtunePrimary, secondary: .pairtuneSecondary)
                .frame(width: 84, height: 36)
        }
        .frame(height: 130)

        VStack(spacing: 8) {
            Text("ペアになりました")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.white)
                .tracking(0.4)

            Text("You and \(partnerName) are now paired")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .tracking(0.4)
        }
        .padding(.top, 32)
        .opacity(pulseTrigger > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.7).delay(1.0), value: pulseTrigger)

        Text("ふたりだけの部屋ができました。\nいつでも、同じ音を。")
            .font(.system(size: 12.5))
            .foregroundColor(Color(hex: "7A7588"))
            .multilineTextAlignment(.center)
            .lineSpacing(5)
            .padding(.top, 18)

        Spacer()

        Button(action: onEnterRoom) {
            HStack(spacing: 10) {
                Text("ふたりの部屋を開く")
                    .font(.system(size: 16, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtunePrimary, Color.pairtuneSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.pairtunePrimary.opacity(0.33), radius: 16, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 36)
        .opacity(pulseTrigger > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.6).delay(1.4), value: pulseTrigger)
    }

    private func celebrationAvatar(initial: String, color: Color) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 72, height: 72)
            .overlay(
                Text(initial)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Color(red: 0x0A/255, green: 0x06/255, blue: 0x12/255))
            )
            .overlay(
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.5)
            )
            .shadow(color: color.opacity(0.40), radius: 16, y: 8)
    }

    private func rippleScale(for i: Int) -> CGFloat {
        pulseTrigger > 0 ? 2.6 : 0.6
    }

    private func rippleOpacity(for i: Int) -> Double {
        pulseTrigger > 0 ? 0 : 0.9
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

    private var displayName: String {
        requester?.displayName ?? "ユーザー"
    }

    private var requesterInitial: String {
        String(displayName.prefix(1)).uppercased()
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Countdown ring

private struct CountdownRingView: View {
    let percent: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: max(0, min(1, percent)))
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("24h")
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "A8A8A8"))
                .tracking(0.2)
        }
    }
}

// MARK: - Celebration wave

private struct CelebrationWaveView: View {
    let primary: Color
    let secondary: Color

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let w = size.width
            let mid = h / 2

            var upper = Path()
            upper.move(to: CGPoint(x: 2, y: mid))
            upper.addQuadCurve(to: CGPoint(x: 22, y: mid), control: CGPoint(x: 12, y: 6))
            upper.addQuadCurve(to: CGPoint(x: 42, y: mid), control: CGPoint(x: 32, y: 6))
            upper.addQuadCurve(to: CGPoint(x: 62, y: mid), control: CGPoint(x: 52, y: 6))
            upper.addQuadCurve(to: CGPoint(x: w - 2, y: mid), control: CGPoint(x: 72, y: 6))

            var lower = Path()
            lower.move(to: CGPoint(x: 2, y: mid))
            lower.addQuadCurve(to: CGPoint(x: 22, y: mid), control: CGPoint(x: 12, y: h - 6))
            lower.addQuadCurve(to: CGPoint(x: 42, y: mid), control: CGPoint(x: 32, y: h - 6))
            lower.addQuadCurve(to: CGPoint(x: 62, y: mid), control: CGPoint(x: 52, y: h - 6))
            lower.addQuadCurve(to: CGPoint(x: w - 2, y: mid), control: CGPoint(x: 72, y: h - 6))

            ctx.stroke(upper, with: .color(primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ctx.stroke(lower, with: .color(secondary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}
